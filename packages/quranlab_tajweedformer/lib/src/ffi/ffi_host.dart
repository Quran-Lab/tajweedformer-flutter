// Windows and Linux: the Dart API on the C SDK (tajweedformer.dll / libtajweedformer.so) through dart:ffi. The
// Client lives here, on the main isolate; the Model and its takes live on the engine isolate (engine.dart); calls
// that wait for the network (a download, a deletion) run on short-lived isolates, so the app's UI never waits. What
// the C SDK cannot do on a desktop is the catalogue's error, never a silent difference: see the README's "Windows
// and Linux". Internal.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../errors.dart';
import '../host.dart';
import '../messages.g.dart';
import 'app_identity.dart';
import 'engine.dart';
import 'native.dart';
import 'sharing_ui.dart';
import 'tajweedformer.g.dart';

class FfiHost with WidgetsBindingObserver implements TajweedHost {
  /// [libraryDir]: the folder of the C SDK's libraries (tests); null: the app's own. [openNative]: tests only, the
  /// libraries of an isolate (a stand-in for the C SDK); it is called on this isolate and inside the short-lived
  /// isolates, so it must be a top-level or static function.
  FfiHost({this.libraryDir, @visibleForTesting this.openNative});

  final String? libraryDir;
  final TfNative Function()? openNative;
  TfNative? _n;
  TfNative get n => _n ??= _opener()();
  TfBindings get tf => n.tf;

  /// How an isolate opens the libraries: sent to the short-lived isolates, so it captures the folder only.
  TfNative Function() _opener() => openNative ?? _openIn(libraryDir);

  /// The calls on short-lived isolates that use the Client: [closeClient] waits for them before it frees it.
  final Set<Future<void>> _inFlight = {};

  /// The lifecycle calls, one after the other in the order the app's state changed.
  Future<void> _lifecycle = Future.value();
  bool _background = false;

  /// Lifecycle calls queued or running. While one is, no ask is shown: tf_client_background takes the ask in hand
  /// back only after it has sent the telemetry, so an ask shown in between would be taken back under a sheet that
  /// stays on screen, and the learner's tap would record nothing.
  int _lifecyclePending = 0;

  /// A call on a short-lived isolate with the Client's address, counted until it ends.
  Future<R> _offClient<R>(R Function(TfNative n, Pointer<TfClient> c) body) {
    final f = _off(_opener(), _c.address, body);
    final done = f.then<void>((_) {}, onError: (Object _) {});
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
    return f;
  }

  Pointer<TfClient> _client = nullptr;
  final List<Pointer> _clientStrings = [];
  final StreamController<UpdateMessage> _updates = StreamController<UpdateMessage>.broadcast();
  ReceivePort? _port;
  SendPort? _engine;
  Completer<SendPort>? _engineReady;
  final Map<int, Completer<Object?>> _calls = {};
  int _nextCall = 1;
  SharingUi? _ui;
  SharingThemeMessage _theme = SharingThemeMessage();
  bool _observing = false;
  Timer? _askWatch;

  Pointer<TfClient> get _c {
    if (_client == nullptr) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'client: it is not made yet',
          fix: 'Call TajweedClient.create first.');
    }
    return _client;
  }

  @override
  Stream<UpdateMessage> updates() => _updates.stream;

  // ---- the engine isolate ----

  Future<SendPort> _engineFor(Pointer<TfClient> client) {
    final ready = _engineReady;
    if (ready != null) return ready.future;
    final c = _engineReady = Completer<SendPort>();
    final port = _port = ReceivePort('quranlab_tajweedformer engine');
    port.listen((Object? m) {
      if (m is SendPort) {
        _engine = m;
        if (!c.isCompleted) c.complete(m);
      } else if (m is EngineReply) {
        final call = _calls.remove(m.id);
        if (call == null) return;
        final e = m.error;
        e == null ? call.complete(m.value) : call.completeError(e);
      } else if (m is UpdateMessage) {
        _updates.add(m);
        if (m is ClosedUpdate) _watchAsks();
      } else if (m is List && m.length == 2) {
        // an uncaught error of the engine isolate ([message, stack]): a fault of the plugin, said where a developer sees it
        debugPrint('quranlab_tajweedformer engine: ${m[0]} ${m[1]}');
      } else if (m == null) {
        // the engine isolate is gone: what waits on it fails now instead of never
        _engine = null;
        _engineReady = null;
        if (!c.isCompleted) {
          c.completeError(const TajweedError(TajweedErrorCode.engineFailed, 'The TajweedFormer engine stopped.'));
        }
        for (final w in _calls.values) {
          if (!w.isCompleted) {
            w.completeError(const TajweedError(TajweedErrorCode.engineFailed, 'The TajweedFormer engine stopped.',
                fix: 'Close the client and make it again; send client.diagnose() with an issue to Quran Lab.'));
          }
        }
        _calls.clear();
      }
    });
    Isolate.spawn(engineMain, EngineStart(port.sendPort, libraryDir, client.address),
            debugName: 'quranlab_tajweedformer engine', errorsAreFatal: false, onError: port.sendPort,
            onExit: port.sendPort)
        .catchError((Object e) {
      if (!c.isCompleted) c.completeError(TajweedError(TajweedErrorCode.engineFailed, 'The engine isolate did not start: $e'));
      return Isolate.current;
    });
    return c.future;
  }

  Future<T> _call<T>(String op, [List<Object?> args = const []]) async {
    final engine = _engine ?? await _engineFor(_c);
    final id = _nextCall++;
    final done = Completer<Object?>();
    _calls[id] = done;
    engine.send(EngineCall(id, op, args));
    return (await done.future) as T;
  }

  Future<void> _stopEngine() async {
    if (_engine != null) {
      try {
        await _call<void>('shutdown');
      } catch (_) {}
    }
    _port?.close();
    _port = null;
    _engine = null;
    _engineReady = null;
    for (final c in _calls.values) {
      c.completeError(const TajweedError(TajweedErrorCode.cancelled, 'The client was closed.'));
    }
    _calls.clear();
  }

  // ---- the client ----

  /// A Quran Lab key, as the other SDKs check it before anything is sent.
  static final _keyFormat = RegExp(r'^qlk_v1_[A-Za-z0-9_-]+$');

  @override
  Future<void> createClient(String key, ClientOptionsMessage options) async {
    if (!_keyFormat.hasMatch(key)) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'Invalid argument: key: this is not a Quran Lab key (qlk_v1_...).',
          fix: "Pass your app's desktop key from sdk.quranlab.ai.");
    }
    final fp = _fingerprint(key);
    final existing = n.slot(TfNative.slotClient);
    if (existing != 0) {
      // a hot restart (debug builds only) finds the Client its earlier Dart made; in a profile or release build a
      // second Client is a second Flutter engine in this process (a multi-window app), which must not take the first
      // engine's Model and takes: one Client per process, as on every platform
      if (n.slot(TfNative.slotKey) != fp || (!kDebugMode && _client == nullptr)) {
        throw const TajweedError(TajweedErrorCode.clientExists, 'A TajweedClient is already open in this process.',
            fix: 'Keep the one client and reuse it; close it before making one with another key.');
      }
      // the same key again: Dart restarted (a hot restart) or a second engine asks; its takes are gone
      if (_client == nullptr) {
        _client = Pointer<TfClient>.fromAddress(existing);
      } else {
        await _stopEngine();
      }
      await _engineFor(_client);
      _attach();
      return;
    }
    final id = options.appId ?? AppIdentity.appId();
    if (id == null) {
      throw TajweedError(TajweedErrorCode.invalidArgument,
          'Invalid argument: appId: this ${defaultTargetPlatform == TargetPlatform.windows ? 'Windows app has no package identity' : 'Linux app has no GTK application id'}.',
          fix: 'Pass TajweedClientOptions(appId: ...) with the app id registered for your desktop key at sdk.quranlab.ai.');
    }
    final version = options.appVersion ?? AppIdentity.version();
    final build = options.appVersion == null ? AppIdentity.build() : null;
    Pointer<Char> keep(String? s) {
      if (s == null) return nullptr;
      final p = s.toNativeUtf8().cast<Char>();
      _clientStrings.add(p);
      return p;
    }

    final o = calloc<TfClientOptions>();
    final ext = calloc<TfClientOptionsExt>();
    try {
      o.ref
        ..key = keep(key)
        ..app_id = keep(id)
        ..app_version = keep(version)
        ..storage = keep(options.storage)
        ..language = keep(PlatformDispatcher.instance.locale.toLanguageTag())
        ..debug = kDebugMode ? 1 : 0;
      ext.ref
        ..size = sizeOf<TfClientOptionsExt>()
        ..app_build = keep(build);
      final c = tf.tf_client_create2(o, ext);
      if (c == nullptr) throw n.lastError();
      _client = c;
      n.setSlot(TfNative.slotKey, fp);
      n.setSlot(TfNative.slotClient, c.address);
    } finally {
      calloc.free(o);
      calloc.free(ext);
    }
    await _engineFor(_client);
    _attach();
  }

  @override
  Future<void> closeClient() async {
    if (_client == nullptr) return;
    await _stopEngine();
    _detach();
    final c = _client.address;
    _client = nullptr;
    // the process's Client, unless another Flutter engine of this process (a debug build's second window, which took
    // the same Client) closed it already: then it is freed, and freeing it again would crash
    final live = n.slot(TfNative.slotClient) == c;
    if (live) {
      n.setSlot(TfNative.slotClient, 0);
      n.setSlot(TfNative.slotKey, 0);
    }
    // a call on another isolate still uses the Client (the storage, a diagnosis, the lifecycle, sharing): it ends
    // before the Client is freed. Nothing new starts: the Client is gone for this Dart already
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
    // tf_client_destroy can wait up to 3 seconds for a request in flight
    if (live) await _off(_opener(), c, _destroyIn);
    for (final p in _clientStrings) {
      calloc.free(p);
    }
    _clientStrings.clear();
  }

  /// FNV-1a 64 of the key: enough to tell the same key again, kept in the process instead of the key.
  static int _fingerprint(String key) {
    var h = 0xcbf29ce484222325;
    for (final b in key.codeUnits) {
      h = (h ^ (b & 0xff)) * 0x100000001b3;
    }
    return h == 0 ? 1 : h;
  }

  void _attach() {
    if (_observing) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // no binding (a test without one): the app's lifecycle is not followed
    }
  }

  void _detach() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    _askWatch?.cancel();
    _ui?.dismiss();
  }

  /// The app left the foreground (hidden or paused) or came back from it. Both C calls wait for the network
  /// (tf_client_background sends the telemetry, tf_client_foreground asks for the config), so they run on a short-lived
  /// isolate, in order, and never on the UI isolate. A window that only loses and regains the focus (inactive) has
  /// not left the foreground: nothing is called for it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_client == nullptr) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_background) return;
        _background = false;
        _lifecycleStep(_foregroundIn);
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        // tf_client_background takes the ask back (a card on screen counts as "Not now", a sheet as shown with no
        // answer): the sheet and the card leave the screen at once with no answer of ours, so a later tap cannot
        // record a consent the SDK no longer holds, and no ask is looked for while the app is away
        _askWatch?.cancel();
        _ui?.withdrawAsk();
        if (_background) return;
        _background = true;
        _lifecycleStep(_backgroundIn);
      default:
        break;
    }
  }

  void _lifecycleStep(void Function(TfNative n, Pointer<TfClient> c) body) {
    _lifecyclePending++;
    _lifecycle = _lifecycle.then((_) {
      if (_client == nullptr) return null;
      return _offClient(body);
    }).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      // the app is in front and the SDK has settled: an ask it holds now is shown (looked for once)
      if (--_lifecyclePending == 0 && !_background && _client != nullptr && _pendingAsk() != 0) unawaited(_present());
    });
  }

  /// Tests: the lifecycle calls made so far have ended.
  @visibleForTesting
  Future<void> get lifecycleSettled => _lifecycle;

  /// Tests: this host takes [address] as its Client (made by a stand-in of the C SDK), with no engine isolate.
  @visibleForTesting
  void adoptClientForTest(int address) {
    _client = Pointer<TfClient>.fromAddress(address);
    n.setSlot(TfNative.slotClient, address);
    _attach();
  }

  @override
  Future<ModelMessage> model(String? version, int? progressId) async {
    final c = _c;
    if (progressId != null && version == null) await _prefetch(c, progressId);
    return _call<ModelMessage>('model', [version]);
  }

  @override
  Future<void> prefetch(int? progressId) => _prefetch(_c, progressId);

  /// The download on its own isolate, its progress sent at most every 100 ms and always at the end.
  Future<void> _prefetch(Pointer<TfClient> c, int? progressId) async {
    final updates = ReceivePort();
    updates.listen((Object? m) {
      if (m is UpdateMessage) _updates.add(m);
    });
    try {
      // not waited for by closeClient: tf_client_destroy ends a download in flight itself
      await _prefetchOff(_opener(), c.address, progressId, updates.sendPort);
    } finally {
      // the progress sent before the end arrives before the port closes
      await Future<void>.delayed(Duration.zero);
      updates.close();
    }
  }

  @override
  Future<StorageMessage> storage() async {
    // off the UI isolate: the call waits for the Client's lock, which a download holds to its end
    final r = await _offClient(_storageIn);
    final m = (jsonOfString(r.json) as Map?)?.cast<String, Object?>();
    if (m == null) throw r.error ?? const TajweedError(TajweedErrorCode.storageFailed, 'The storage could not be read.');
    return StorageMessage(
      models: [
        for (final s in (m['models'] as List?) ?? const [])
          if (s is Map)
            StoredModelMessage(version: '${s['version']}', build: '${s['build']}', bytes: (s['bytes'] as num?)?.toInt() ?? 0),
      ],
      sharingQueueBytes: (m['sharingQueueBytes'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> removeModels() async {
    _c;
    await _call<void>('closeModel');
    await _offClient(_removeModelsIn);
  }

  @override
  Future<String> diagnose() async {
    // off the UI isolate: a diagnosis during the first download must not freeze the window
    final r = await _offClient(_diagnoseIn);
    final s = r.json;
    if (s == null) throw r.error ?? const TajweedError(TajweedErrorCode.engineFailed, 'The diagnosis failed.');
    return s;
  }

  @override
  Future<BackendMessage> modelBackend() => _call('modelBackend');

  @override
  Future<void> closeModel() => _client == nullptr ? Future.value() : _call('closeModel');

  // ---- takes ----

  @override
  Future<void> openSession(int sessionId, String mode, SessionOptionsMessage options, String? clipName,
      Uint8List? samples, int? sampleRate) {
    // a take starting takes the card away: the SDK counts a card on screen as "Not now" when the take really starts
    // (nothing is answered here: listen() on the desktop, or a take that fails to open, records nothing)
    _ui?.withdrawCard();
    return _call('openSession', [sessionId, mode, options, clipName, samples, sampleRate]);
  }

  @override
  Future<void> push(int sessionId, Uint8List pcm, bool int16) => _call('push', [sessionId, pcm, int16]);

  @override
  Future<HeadsMessage> finish(int sessionId) => _call('finish', [sessionId]);

  @override
  Future<void> cancel(int sessionId) => _call('cancel', [sessionId]);

  @override
  Future<BackendMessage> sessionBackend(int sessionId) => _call('sessionBackend', [sessionId]);

  @override
  Future<void> reportRecited(int sessionId, int surah, int ayahFrom, int ayahTo, RecitedOutcomeMessage? outcome,
          List<RecitedOutcomeMessage> perAyah) =>
      _call('reportRecited', [sessionId, surah, ayahFrom, ayahTo, outcome, perAyah]);

  // ---- the reference data ----

  @override
  Future<bool> referenceIsDownloaded() => _call('referenceIsDownloaded');

  @override
  Future<void> referenceFetch() => _call('referenceFetch');

  @override
  Future<UnitsMessage> referenceUnits(int surah, int ayah) => _call('referenceUnits', [surah, ayah]);

  // ---- sharing ----

  @override
  Future<SharingStateMessage> sharingState() async {
    final c = _c;
    final s = calloc<TfSharing>();
    final code = calloc<Char>(33);
    try {
      n.check(tf.tf_sharing_status(c, s));
      n.check(tf.tf_sharing_recovery_code(c, code));
      final rc = str(code);
      return SharingStateMessage(available: s.ref.is_available != 0, on: s.ref.is_on != 0, recoveryCode: rc == null || rc.isEmpty ? null : rc);
    } finally {
      calloc.free(s);
      calloc.free(code);
    }
  }

  @override
  Future<void> sharingSetOn(bool on) async {
    _c;
    if (!on) _ui?.withdrawCard();
    // off stops an upload in flight: up to 3 seconds
    await _offClient(on ? _sharingOnIn : _sharingOffIn);
  }

  @override
  Future<bool> sharingAsk() async {
    _c;
    // after the lifecycle calls already made: an ask decided before tf_client_background ran would be taken back
    await _lifecycle;
    if (_background) return false;
    final c = _c;
    final rc = tf.tf_sharing_ask(c);
    if (rc < 0) {
      final e = n.lastError();
      // Quran Lab's switch has sharing off: no ask is due, as on the other platforms
      if (e.code == TajweedErrorCode.sharingUnavailable) return false;
      throw e;
    }
    if (rc == 0) return false;
    return _present();
  }

  /// After a take ends the SDK may hand an ask over (3 s later, by its rules): it is looked for for a few seconds.
  void _watchAsks() {
    _askWatch?.cancel();
    var left = 10;
    _askWatch = Timer.periodic(const Duration(seconds: 1), (t) {
      if (--left <= 0 || _client == nullptr) t.cancel();
      if (_pendingAsk() != 0) {
        t.cancel();
        unawaited(_present());
      }
    });
  }

  /// The kind of the ask in hand, or 0.
  int _pendingAsk() {
    if (_client == nullptr) return 0;
    final s = calloc<TfSharing>();
    try {
      if (tf.tf_sharing_status(_client, s) < 0) return 0;
      return s.ref.pending_ask != 0 ? (s.ref.pending_kind == 0 ? TfAskKind.TF_ASK_SHEET.value : s.ref.pending_kind) : 0;
    } finally {
      calloc.free(s);
    }
  }

  /// Draws the ask in hand (the sheet or the card) and tells the SDK it is on screen; false when the app has nowhere
  /// to show it (the ask is then withdrawn: it never reached the screen).
  Future<bool> _present() async {
    // an app away from the foreground shows nothing (the SDK takes the ask back there, tf_client_background), nor
    // one whose lifecycle calls have not returned yet
    if (_background || _lifecyclePending > 0) return false;
    final kind = _pendingAsk();
    if (kind == 0) return false;
    final ui = _ui ??= SharingUi(this);
    return ui.presentAsk(kind == TfAskKind.TF_ASK_CARD.value, _theme);
  }

  // what the drawn sheet calls

  /// The client's copy deck, with the app's own wording.
  Map<String, Object?> copyDeck() => (jsonOf(tf.tf_sharing_copy_json(_c)) as Map?)?.cast<String, Object?>() ?? const {};

  /// The status in hand: the re-ask line, the consent version.
  ({bool reask, String? consentVersion}) askState() {
    final s = calloc<TfSharing>();
    try {
      tf.tf_sharing_status(_c, s);
      return (reask: s.ref.asks > 0, consentVersion: str(s.ref.consent_version));
    } finally {
      calloc.free(s);
    }
  }

  /// The ask is on screen: true when it counts and stays.
  bool shown() => tf.tf_sharing_shown(_c) == 1;

  /// The learner's tap: share (the sheet only) or not now. False when the SDK recorded nothing (the ask was taken
  /// back meanwhile): the ask in hand, if any, is shown again, never answered for the learner.
  bool answer(bool share) {
    if (_client == nullptr) return false;
    if (tf.tf_sharing_answer(_client, share ? 1 : 0) >= 0) return true;
    debugPrint('quranlab_tajweedformer: the sharing answer was not recorded (${n.lastError().message})');
    if (_pendingAsk() != 0) unawaited(_present());
    return false;
  }

  /// The ask on screen while the client is open; false when it was closed meanwhile.
  bool shownSafely() => _client != nullptr && tf.tf_sharing_shown(_client) == 1;

  /// A card's "See how it helps": the SDK hands over the full sheet for the same ask.
  bool openCard() => tf.tf_sharing_open(_c) >= 0 && _pendingAsk() == TfAskKind.TF_ASK_SHEET.value;

  @override
  Future<void> sharingFeed(Uint8List pcm, bool int16, int sampleRate) async {
    final count = sampleCount(pcm, int16);
    if (count == 0) return;
    final p = samplesOf(pcm, int16);
    try {
      n.check(tf.tf_sharing_feed(_c, p, count, sampleRate));
    } finally {
      calloc.free(p);
    }
  }

  @override
  Future<List<SharingItemMessage>> sharingItems() async {
    // off the UI isolate: tf_sharing_items_json waits for the Client's lock, which a download holds to its end
    final r = await _offClient(_itemsIn);
    final v = jsonOfString(r.json);
    if (v is! List) throw r.error ?? const TajweedError(TajweedErrorCode.storageFailed, 'The sharing queue could not be read.');
    return [
      for (final i in v)
        if (i is Map)
          SharingItemMessage(
            status: i['completed'] == true ? 'uploaded' : (i['error'] != null ? 'failed' : 'queued'),
            day: _day((i['created'] as num?)?.toInt() ?? 0),
            // the C SDK's outbox has no duration or size per recording (README: Windows and Linux)
            durationMs: 0,
            bytes: 0,
          ),
    ];
  }

  static String _day(int unixSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<SharingSummaryMessage?> sharingSummary() async {
    // a request to Quran Lab; its answer is the thread's own buffer
    final json = await _offClient(_summaryIn);
    if (json == null) return null;
    final m = (jsonOfString(json) as Map?)?.cast<String, Object?>();
    if (m == null) return null;
    Map<String, Object?> part(String k) => (m[k] as Map?)?.cast<String, Object?>() ?? const {};
    final you = part('you'), app = m['app'] is Map ? part('app') : null, all = part('all');
    return SharingSummaryMessage(
      mySessions: (you['sessions'] as num?)?.toInt() ?? 0,
      myMinutes: (you['minutes'] as num?)?.toDouble() ?? 0,
      appContributors: (app?['contributors'] as num?)?.toInt(),
      appMinutes: (app?['minutes'] as num?)?.toDouble(),
      allContributors: (all['contributors'] as num?)?.toInt() ?? 0,
      allMinutes: (all['minutes'] as num?)?.toDouble() ?? 0,
    );
  }

  @override
  Future<bool> sharingDelete() async {
    _ui?.withdrawCard();
    final code = await _offClient(_deleteIn);
    if (code == null) return true;
    // as on Android and iOS: a device that cannot read the learner's keys is an error; no connection or a refusal
    // is false (nothing changed, try again)
    if (code.code == TajweedErrorCode.storageFailed) throw code;
    return false;
  }

  @override
  Future<void> sharingSetWording(Map<String, String>? overrides) async {
    final c = _c;
    final entries = (overrides ?? const {}).entries.toList();
    final arena = Arena();
    try {
      final keys = arena<Pointer<Char>>(entries.isEmpty ? 1 : entries.length);
      final texts = arena<Pointer<Char>>(entries.isEmpty ? 1 : entries.length);
      for (var i = 0; i < entries.length; i++) {
        keys[i] = entries[i].key.toNativeUtf8(allocator: arena).cast<Char>();
        texts[i] = entries[i].value.toNativeUtf8(allocator: arena).cast<Char>();
      }
      n.check(tf.tf_sharing_set_wording(c, keys, texts, entries.length));
    } finally {
      arena.releaseAll();
    }
  }

  @override
  Future<void> sharingSetTheme(SharingThemeMessage theme) async => _theme = theme;

  @override
  Future<void> sharingOpenSettings() async {
    _c;
    final ui = _ui ??= SharingUi(this);
    if (!await ui.openSettings(_theme)) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'Invalid argument: the app has no Overlay to open the settings on.',
          fix: 'Open the settings from a screen of a MaterialApp, CupertinoApp or WidgetsApp (an app with a Navigator).');
    }
  }

  @override
  Future<void> reportChecks(String rule, int checked, int flagged) async {
    final r = rule.toNativeUtf8();
    try {
      n.check(tf.tf_client_report_checks(_c, r.cast<Char>(), checked, flagged));
    } finally {
      calloc.free(r);
    }
  }

  // what the drawn settings call

  Future<SharingStateMessage> state() => sharingState();
  Future<void> setOn(bool on) => sharingSetOn(on);
  Future<bool> deleteShared() => sharingDelete();
  Future<SharingSummaryMessage?> summary() => sharingSummary();
}

// ---- the calls that wait (the network, a request in flight), each on a short-lived isolate ----
//
// Top-level, so that what crosses to the isolate is how to open the libraries, the Client's address and the call.

/// The libraries of the folder [dir], opened in the isolate that calls the function (top-level: it captures [dir]
/// only).
TfNative Function() _openIn(String? dir) => () => TfNative.open(dir);

Future<R> _off<R>(TfNative Function() open, int client, R Function(TfNative n, Pointer<TfClient> c) body) =>
    Isolate.run(() => body(open(), Pointer<TfClient>.fromAddress(client)));

/// The app left the foreground: the telemetry counted so far is sent, the ask in hand is taken back.
void _backgroundIn(TfNative n, Pointer<TfClient> c) => n.tf.tf_client_background(c);

/// The app is back: the config is asked again (a conditional request), a new app session after 30 minutes away.
void _foregroundIn(TfNative n, Pointer<TfClient> c) => n.tf.tf_client_foreground(c);

({String? json, TajweedError? error}) _itemsIn(TfNative n, Pointer<TfClient> c) {
  final s = str(n.tf.tf_sharing_items_json(c));
  return (json: s, error: s == null ? n.lastError(fallbackCode: TajweedErrorCode.storageFailed) : null);
}

void _destroyIn(TfNative n, Pointer<TfClient> c) => n.tf.tf_client_destroy(c);

void _sharingOnIn(TfNative n, Pointer<TfClient> c) => n.check(n.tf.tf_sharing_set_on(c, 1));

void _sharingOffIn(TfNative n, Pointer<TfClient> c) => n.check(n.tf.tf_sharing_set_on(c, 0));

String? _summaryIn(TfNative n, Pointer<TfClient> c) => str(n.tf.tf_sharing_summary_json(c));

TajweedError? _deleteIn(TfNative n, Pointer<TfClient> c) => n.tf.tf_sharing_delete(c) >= 0 ? null : n.lastError();

({String? json, TajweedError? error}) _storageIn(TfNative n, Pointer<TfClient> c) {
  final s = str(n.tf.tf_client_storage_json(c));
  return (json: s, error: s == null ? n.lastError(fallbackCode: TajweedErrorCode.storageFailed) : null);
}

({String? json, TajweedError? error}) _diagnoseIn(TfNative n, Pointer<TfClient> c) {
  final s = str(n.tf.tf_client_diagnose_json(c));
  return (json: s, error: s == null ? n.lastError() : null);
}

void _removeModelsIn(TfNative n, Pointer<TfClient> c) => n.check(n.tf.tf_client_remove_models(c));

Future<void> _prefetchOff(TfNative Function() open, int client, int? progressId, SendPort to) => Isolate.run(() {
      final n = open();
      final o = calloc<TfPrefetchOptions>();
      NativeCallable<Void Function(Pointer<Void>, LongLong, LongLong)>? cb;
      try {
        if (progressId != null) {
          var last = -1;
          cb = NativeCallable<Void Function(Pointer<Void>, LongLong, LongLong)>.isolateLocal(
              (Pointer<Void> _, int done, int total) {
            final now = DateTime.now().millisecondsSinceEpoch;
            if (done < total && now - last < 100) return;
            last = now;
            to.send(ProgressUpdate(callId: progressId, done: done, total: total));
          });
          o.ref.on_progress = cb.nativeFunction;
        }
        if (n.tf.tf_client_prefetch(Pointer<TfClient>.fromAddress(client), o) < 0) throw n.lastError();
      } finally {
        cb?.close();
        calloc.free(o);
      }
    });
