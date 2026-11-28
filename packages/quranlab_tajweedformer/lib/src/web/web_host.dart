// The web: the Dart API on Quran Lab's hosted loader (https://web.quranlab.ai/4/loader.js), the same loader the npm
// package @quran-lab/tajweedformer loads. The loader opens Quran Lab's frame on the page: the engine, the model's
// ciphertext, the install keys and the lease live in the frame's Worker on Quran Lab's origin, with the web SDK's own
// storage, lease and bot check; the consent sheet and the microphone are the loader's, in this page. So everything
// behind this file is the web SDK's own behaviour. Internal.
//
// The page needs the web SDK's Content-Security-Policy lines (README: "The web").
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:web/web.dart' as web;

import '../delta.dart';
import '../errors.dart';
import '../host.dart';
import '../messages.g.dart';

/// The loader's hosts, in the web SDK's order (ENDPOINTS_40.md 28.6): the next one when the one before failed or has
/// not loaded within 4 seconds.
const loaderUrls = [
  'https://web.quranlab.ai/4/loader.js',
  'https://web2.quranlab.ai/4/loader.js',
  'https://web-b.tajweedformer.com/4/loader.js',
  'https://web-g.tajweedformer.com/4/loader.js',
  'https://web-a.tajweedformer.com/4/loader.js',
];

class WebHost implements TajweedHost {
  WebHost();

  final StreamController<UpdateMessage> _updates = StreamController<UpdateMessage>.broadcast();
  final Map<int, _WebTake> _takes = {};
  JSObject? _client;
  JSObject? _model;

  /// What survives a hot restart: the page's client and its key, on the page itself.
  static const _keep = '__quranlabTajweedFormerFlutter';

  @override
  Stream<UpdateMessage> updates() => _updates.stream;

  JSObject get _c {
    final c = _client;
    if (c == null) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'client: it is not made yet',
          fix: 'Call TajweedClient.create first.');
    }
    return c;
  }

  JSObject get _m {
    final m = _model;
    if (m == null) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'model: it is closed', fix: 'Call client.model() again.');
    }
    return m;
  }

  // ---- the loader ----

  static Future<JSObject>? _loading;

  /// The loader's API 4 object (`QuranLab.v4`), loading the script from the next host when one fails.
  static Future<JSObject> _api() {
    final now = _apiNow();
    if (now != null) return Future.value(now);
    return _loading ??= () async {
      final done = Completer<JSObject>();
      var failed = 0, next = 0;
      Timer? timer;
      void start() {
        if (done.isCompleted || next >= loaderUrls.length) return;
        final i = next++;
        timer?.cancel();
        if (next < loaderUrls.length) timer = Timer(const Duration(seconds: 4), start);
        final s = web.document.createElement('script') as web.HTMLScriptElement
          ..src = loaderUrls[i]
          ..async = true
          ..crossOrigin = 'anonymous';
        s.onload = ((web.Event _) {
          final api = _apiNow();
          if (api != null) {
            timer?.cancel();
            if (!done.isCompleted) done.complete(api);
          } else if (++failed == loaderUrls.length) {
            timer?.cancel();
            if (!done.isCompleted) {
              done.completeError(
                  const TajweedError(TajweedErrorCode.needsConnection, 'The Quran Lab loader did not start.'));
            }
          } else if (i == next - 1) {
            // as the npm wrapper (web/index.js loadQuranLab): a script that loaded without the API counts as a failed
            // host, and the newest one's failure starts the next at once
            start();
          }
        }).toJS;
        s.onerror = ((web.Event _) {
          s.remove();
          if (++failed == loaderUrls.length) {
            timer?.cancel();
            if (!done.isCompleted) {
              done.completeError(const TajweedError(TajweedErrorCode.needsConnection,
                  'The Quran Lab loader could not be loaded from any of its hosts.',
                  fix: 'Check the connection, and that the page\'s Content-Security-Policy allows Quran Lab\'s hosts '
                      '(script-src, frame-src, connect-src: see the README).',
                  cause: TajweedErrorCause(stage: 'runtime', reason: 'loader', needs: 'model')));
            }
          } else if (i == next - 1) {
            start();
          }
        }).toJS;
        (web.document.head ?? web.document.documentElement!).appendChild(s);
      }

      start();
      try {
        return await done.future;
      } catch (_) {
        _loading = null;
        rethrow;
      }
    }();
  }

  /// The loader's API 4 object, loaded as the host loads it, for the live check (test/web_loader_live_test.dart).
  @visibleForTesting
  static Future<JSObject> loadApiForTest() => _api();

  static JSObject? _apiNow() {
    final q = globalContext.getProperty<JSAny?>('QuranLab'.toJS);
    if (q == null || !q.isA<JSObject>()) return null;
    final o = q as JSObject;
    if (_num(o, 'api') != 4) return null;
    return o.getProperty<JSObject>('v4'.toJS);
  }

  // ---- the client ----

  @override
  Future<void> createClient(String key, ClientOptionsMessage options) async {
    final api = await _api();
    final kept = globalContext.getProperty<JSAny?>(_keep.toJS);
    if (kept != null && kept.isA<JSObject>()) {
      final k = kept as JSObject;
      if (_str(k, 'key') != key) {
        throw const TajweedError(TajweedErrorCode.clientExists, 'A TajweedClient is already open in this page.',
            fix: 'Keep the one client and reuse it; close it before making one with another key.');
      }
      // the same key again: Dart restarted (a hot restart); the takes of the Dart that is gone are cancelled
      _client = k.getProperty<JSObject>('client'.toJS);
      // the take this plugin last opened, kept beside the client (the loader's own objects are read through their
      // public API only); cancelling an ended take does nothing
      final session = k.getProperty<JSAny?>('session'.toJS);
      if (session != null && session.isA<JSObject>()) {
        await _await(_call(session as JSObject, 'cancel')).then<void>((_) {}, onError: (Object _) {});
      }
      k.delete('session'.toJS);
      return;
    }
    final o = JSObject()..setProperty('key'.toJS, key.toJS);
    if (options.appVersion != null) o.setProperty('appVersion'.toJS, options.appVersion!.toJS);
    if (options.storage != null) o.setProperty('storage'.toJS, options.storage!.toJS);
    final client = await _await(_call(api.getProperty<JSObject>('TajweedClient'.toJS), 'create', [o])) as JSObject;
    _client = client;
    globalContext.setProperty(
        _keep.toJS,
        JSObject()
          ..setProperty('key'.toJS, key.toJS)
          ..setProperty('client'.toJS, client));
  }

  @override
  Future<void> closeClient() async {
    final c = _client;
    if (c == null) return;
    for (final t in _takes.values.toList()) {
      t.close(this);
    }
    _takes.clear();
    _model = null;
    _client = null;
    globalContext.delete(_keep.toJS);
    await _await(_call(c, 'close'));
  }

  @override
  Future<ModelMessage> model(String? version, int? progressId) async {
    final c = _c;
    if (progressId != null && version == null) await _prefetch(c, progressId);
    final m = await _await(_call(c, 'model', [if (version != null) version.toJS])) as JSObject;
    _model = m;
    final kept = globalContext.getProperty<JSAny?>(_keep.toJS);
    if (kept != null && kept.isA<JSObject>()) (kept as JSObject).setProperty('model'.toJS, m);
    return _modelMessage(m);
  }

  ModelMessage _modelMessage(JSObject m) {
    final contexts = _strings(m.getProperty('contexts'.toJS));
    final tokens = m.getProperty<JSObject>('tokens'.toJS);
    final count = _num(tokens, 'count') ?? 0;
    final names = [
      for (var i = 0; i < count; i++) _jsString(tokens.callMethod<JSAny?>('name'.toJS, i.toJS)) ?? '?',
    ];
    final wordBar = _num(tokens, 'wordBar');
    final cal = m.getProperty<JSAny?>('calibration'.toJS);
    final clips = m.getProperty<JSAny?>('sampleClips'.toJS);
    return ModelMessage(
      id: _str(m, 'id') ?? '',
      version: _str(m, 'version') ?? '',
      build: _str(m, 'build') ?? '',
      contexts: contexts,
      chunkMs: [for (final c in contexts) _jsInt(m.callMethod<JSAny?>('chunkMs'.toJS, c.toJS)) ?? 0],
      defaultContext: _str(m, 'defaultContext') ?? (contexts.isEmpty ? '' : contexts.first),
      tokens: TokensMessage(
          names: names,
          blank: _num(tokens, 'blank') ?? 0,
          wordBar: wordBar != null && wordBar >= 0 && wordBar < names.length && names[wordBar] == '|' ? wordBar : null),
      calibration: cal == null || !cal.isA<JSObject>()
          ? null
          : CalibrationMessage(json: _str(cal as JSObject, 'text') ?? '{}', sha256: _str(cal, 'sha256') ?? ''),
      hasReference: _isObject(m.getProperty('reference'.toJS)),
      sampleClips: [
        for (final c in _objects(clips))
          ClipMessage(name: _str(c, 'name') ?? '', kind: _str(c, 'kind') ?? 'clean', durationMs: _num(c, 'durationMs') ?? 0),
      ],
      backend: _backend(m.getProperty('backend'.toJS)),
    );
  }

  @override
  Future<void> prefetch(int? progressId) => _prefetch(_c, progressId);

  Future<void> _prefetch(JSObject c, int? progressId) async {
    final o = JSObject();
    if (progressId != null) {
      var last = 0;
      o.setProperty(
          'onProgress'.toJS,
          ((JSObject p) {
            final done = _num(p, 'bytesDone') ?? 0, total = _num(p, 'bytesTotal') ?? 0;
            final now = DateTime.now().millisecondsSinceEpoch;
            if (done < total && now - last < 100) return;
            last = now;
            _updates.add(ProgressUpdate(callId: progressId, done: done, total: total));
          }).toJS);
    }
    final r = await _await(_call(c, 'prefetch', [o]));
    if (progressId != null && r != null && r.isA<JSObject>()) {
      final done = _num(r as JSObject, 'bytesDone') ?? 0, total = _num(r, 'bytesTotal') ?? done;
      _updates.add(ProgressUpdate(callId: progressId, done: done, total: total));
    }
  }

  @override
  Future<StorageMessage> storage() async {
    final s = await _await(_call(_c, 'storage')) as JSObject;
    return StorageMessage(
      models: [
        for (final m in _objects(s.getProperty('models'.toJS)))
          StoredModelMessage(version: _str(m, 'version') ?? '', build: _str(m, 'build') ?? '', bytes: _num(m, 'bytes') ?? 0),
      ],
      sharingQueueBytes: _num(s, 'sharingQueueBytes') ?? 0,
    );
  }

  @override
  Future<void> removeModels() async {
    final c = _c;
    _closeTakes();
    _model = null;
    await _await(_call(c, 'removeModels'));
  }

  @override
  Future<String> diagnose() async {
    final d = await _await(_call(_c, 'diagnose'));
    final json = globalContext.getProperty<JSObject>('JSON'.toJS);
    return _jsString(json.callMethod<JSAny?>('stringify'.toJS, d)) ?? '{}';
  }

  @override
  Future<BackendMessage> modelBackend() async => _backend(_m.getProperty('backend'.toJS));

  @override
  Future<void> closeModel() async {
    final m = _model;
    if (m == null) return;
    _closeTakes();
    _model = null;
    await _await(_call(m, 'close'));
  }

  void _closeTakes() {
    for (final t in _takes.values.toList()) {
      t.close(this);
    }
    _takes.clear();
  }

  // ---- takes ----

  @override
  Future<void> openSession(int sessionId, String mode, SessionOptionsMessage options, String? clipName,
      Uint8List? samples, int? sampleRate) async {
    final m = _m;
    // the takes that ended make room (an open one is the SDK's session_open)
    _takes.removeWhere((_, t) => t.over);
    final o = JSObject();
    if (options.context != null) o.setProperty('context'.toJS, options.context!.toJS);
    final heads = options.heads;
    if (heads != null) {
      o.setProperty('heads'.toJS, heads.length == 1 && heads[0] == 'all' ? 'all'.toJS : heads.map((h) => h.toJS).toList().toJS);
    }
    // the web runs the CPU engine in WebAssembly: auto and the compact CoreML build are both that
    o.setProperty('backend'.toJS, (options.backend == 'cpu' ? 'cpu' : 'auto').toJS);
    o.setProperty('topK'.toJS, options.topK.toJS);
    if (options.endOnSilenceMs != null) o.setProperty('endOnSilenceMs'.toJS, options.endOnSilenceMs!.toJS);
    JSObject session;
    switch (mode) {
      case 'listen':
        session = await _await(_call(m, 'listen', [o])) as JSObject;
      case 'clip':
        final clip = _objects(m.getProperty('sampleClips'.toJS)).where((c) => _str(c, 'name') == clipName).firstOrNull;
        if (clip == null) {
          throw TajweedError(TajweedErrorCode.invalidArgument, 'Invalid argument: clip: $clipName is not one of model.sampleClips.',
              fix: 'Pass one of model.sampleClips.');
        }
        o
          ..setProperty('from'.toJS, clip)
          ..setProperty('pace'.toJS, options.pace.toJS);
        session = await _await(_call(m, 'listen', [o])) as JSObject;
      case 'samples':
        final s = samples ?? Uint8List(0);
        o
          ..setProperty('from'.toJS, Float32List.fromList(s.buffer.asFloat32List(s.offsetInBytes, s.lengthInBytes ~/ 4)).toJS)
          ..setProperty('sampleRate'.toJS, (sampleRate ?? 16000).toJS)
          ..setProperty('pace'.toJS, options.pace.toJS);
        session = await _await(_call(m, 'listen', [o])) as JSObject;
      case 'push':
        o.setProperty('sampleRate'.toJS, options.sampleRate.toJS);
        session = await _await(_call(m, 'session', [o])) as JSObject;
      default:
        throw TajweedError(TajweedErrorCode.invalidArgument, 'mode: $mode is not listen, clip, samples or push',
            fix: 'Update the plugin.');
    }
    final t = _WebTake(sessionId, session, DeltaEncoder(options.topK));
    _takes[sessionId] = t;
    final kept = globalContext.getProperty<JSAny?>(_keep.toJS);
    if (kept != null && kept.isA<JSObject>()) (kept as JSObject).setProperty('session'.toJS, session);
    t.start(this);
  }

  _WebTake _take(int id) {
    final t = _takes[id];
    if (t == null) {
      throw const TajweedError(TajweedErrorCode.sessionClosed, 'This take is over.',
          fix: 'Start a new take with model.listen() or model.session().');
    }
    return t;
  }

  @override
  Future<void> push(int sessionId, Uint8List pcm, bool int16) async {
    final t = _take(sessionId);
    final Float32List samples;
    if (int16) {
      final d = ByteData.sublistView(pcm);
      samples = Float32List(pcm.lengthInBytes ~/ 2);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = d.getInt16(i * 2, Endian.little) / 32768;
      }
    } else {
      samples = Float32List.fromList(pcm.buffer.asFloat32List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 4));
    }
    await _await(_call(t.session, 'push', [samples.toJS]));
  }

  @override
  Future<HeadsMessage> finish(int sessionId) async {
    final t = _take(sessionId);
    final h = await _await(_call(t.session, 'finish')) as JSObject;
    final decoded = await _await(_call(h, 'decoded')) as JSObject;
    return HeadsMessage(heads: _heads(h), decoded: t.encoder.whole(_decoded(decoded)));
  }

  @override
  Future<void> cancel(int sessionId) async {
    final t = _takes[sessionId];
    if (t == null) return;
    await _await(_call(t.session, 'cancel'));
  }

  @override
  Future<BackendMessage> sessionBackend(int sessionId) async => _backend(_take(sessionId).session.getProperty('backend'.toJS));

  @override
  Future<void> reportRecited(int sessionId, int surah, int ayahFrom, int ayahTo, RecitedOutcomeMessage? outcome,
      List<RecitedOutcomeMessage> perAyah) async {
    final t = _take(sessionId);
    JSObject out(RecitedOutcomeMessage m) {
      final o = JSObject()..setProperty('correct'.toJS, m.correct.toJS);
      if (!m.correct) {
        if (m.mistakes != null) o.setProperty('mistakes'.toJS, m.mistakes!.toJS);
        o.setProperty('rules'.toJS, m.rules.map((r) => r.toJS).toList().toJS);
      }
      return o;
    }

    final o = JSObject();
    if (outcome != null) o.setProperty('outcome'.toJS, out(outcome));
    if (perAyah.isNotEmpty) {
      final per = JSObject();
      for (final p in perAyah) {
        if (p.ayah == null) {
          throw const TajweedError(TajweedErrorCode.invalidArgument, 'Invalid argument: perAyah: an entry names no ayah.',
              fix: 'Name the ayah of every per-ayah outcome.');
        }
        per.setProperty('${p.ayah}'.toJS, out(p));
      }
      o.setProperty('perAyah'.toJS, per);
    }
    await _await(_call(t.session, 'reportRecited', [surah.toJS, ayahFrom.toJS, ayahTo.toJS, o]));
  }

  // ---- the reference data ----

  JSObject _reference() {
    final r = _m.getProperty<JSAny?>('reference'.toJS);
    if (r == null || !r.isA<JSObject>()) {
      throw const TajweedError(TajweedErrorCode.referenceMissing, 'This model build ships no reference data.',
          fix: 'Check model.reference before using it.');
    }
    return r as JSObject;
  }

  @override
  Future<bool> referenceIsDownloaded() async => _bool(_reference(), 'isDownloaded') ?? false;

  @override
  Future<void> referenceFetch() async => _await(_call(_reference(), 'fetch'));

  @override
  Future<UnitsMessage> referenceUnits(int surah, int ayah) async {
    final r = await _await(_call(_reference(), 'units', [surah.toJS, ayah.toJS])) as JSObject;
    final units = _ints(r.getProperty('units'.toJS));
    final words = _ints(r.getProperty('words'.toJS));
    final starts = <int>[];
    for (var k = 0; k < words.length; k++) {
      if (words[k] == starts.length) starts.add(k);
    }
    return UnitsMessage(units: Int32List.fromList(units), wordStarts: Int32List.fromList(starts));
  }

  // ---- sharing ----

  JSObject get _sharing => _c.getProperty<JSObject>('sharing'.toJS);

  @override
  Future<SharingStateMessage> sharingState() async {
    final s = _sharing;
    return SharingStateMessage(
        available: _bool(s, 'isAvailable') ?? false, on: _bool(s, 'isOn') ?? false, recoveryCode: _str(s, 'recoveryCode'));
  }

  @override
  Future<void> sharingSetOn(bool on) => _await(_call(_sharing, 'setOn', [on.toJS]));

  @override
  Future<bool> sharingAsk() async {
    try {
      final r = await _await(_call(_sharing, 'ask'));
      // the web SDK answers once the learner has answered (an ask that was shown), or null when none was due
      return r != null && r.isA<JSObject>();
    } on TajweedError catch (e) {
      if (e.code == TajweedErrorCode.sharingUnavailable) return false;
      rethrow;
    }
  }

  @override
  Future<void> sharingFeed(Uint8List pcm, bool int16, int sampleRate) async {
    final Float32List samples;
    if (int16) {
      final d = ByteData.sublistView(pcm);
      samples = Float32List(pcm.lengthInBytes ~/ 2);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = d.getInt16(i * 2, Endian.little) / 32768;
      }
    } else {
      samples = Float32List.fromList(pcm.buffer.asFloat32List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 4));
    }
    await _await(_call(_sharing, 'feed', [samples.toJS, sampleRate.toJS]));
  }

  @override
  Future<List<SharingItemMessage>> sharingItems() async {
    final items = await _await(_call(_sharing, 'items'));
    return [
      for (final i in _objects(items))
        SharingItemMessage(
          status: _str(i, 'status') ?? 'queued',
          day: _str(i, 'day') ?? '',
          durationMs: _num(i, 'durationMs') ?? 0,
          bytes: _num(i, 'bytes') ?? 0,
        ),
    ];
  }

  @override
  Future<SharingSummaryMessage?> sharingSummary() async {
    final r = await _await(_call(_sharing, 'summary'));
    if (r == null || !r.isA<JSObject>()) return null;
    final s = r as JSObject;
    JSObject? part(String k) {
      final v = s.getProperty<JSAny?>(k.toJS);
      return v != null && v.isA<JSObject>() ? v as JSObject : null;
    }

    final you = part('you'), app = part('app'), all = part('all');
    return SharingSummaryMessage(
      mySessions: you == null ? 0 : _num(you, 'sessions') ?? 0,
      myMinutes: you == null ? 0 : _double(you, 'minutes') ?? 0,
      appContributors: app == null ? null : _num(app, 'contributors'),
      appMinutes: app == null ? null : _double(app, 'minutes'),
      allContributors: all == null ? 0 : _num(all, 'contributors') ?? 0,
      allMinutes: all == null ? 0 : _double(all, 'minutes') ?? 0,
    );
  }

  @override
  Future<bool> sharingDelete() async {
    try {
      await _await(_call(_sharing, 'delete'));
      return true;
    } on TajweedError catch (e) {
      // as on Android and iOS: a device that cannot read the learner's keys is an error; no connection or a refusal
      // is false (nothing changed, try again)
      if (e.code == TajweedErrorCode.storageFailed) rethrow;
      return false;
    }
  }

  @override
  Future<void> sharingSetWording(Map<String, String>? overrides) async {
    JSObject? o;
    if (overrides != null && overrides.isNotEmpty) {
      o = JSObject();
      for (final e in overrides.entries) {
        o.setProperty(e.key.toJS, e.value.toJS);
      }
    }
    await _await(_call(_sharing, 'setWording', [o]));
  }

  /// The theme as the web SDK's CSS custom properties, on the page's root: the sheet, the card and the settings
  /// element read them.
  @override
  Future<void> sharingSetTheme(SharingThemeMessage theme) async {
    final style = (web.document.documentElement! as web.HTMLElement).style;
    void set(String name, Object? v) {
      if (v == null) {
        style.removeProperty(name);
      } else {
        style.setProperty(name, '$v');
      }
    }

    String? css(int? argb) {
      if (argb == null) return null;
      final a = ((argb >> 24) & 0xff) / 255, r = (argb >> 16) & 0xff, g = (argb >> 8) & 0xff, b = argb & 0xff;
      return 'rgb($r $g $b / ${a.toStringAsFixed(3)})';
    }

    set('--ql-accent', css(theme.accent));
    set('--ql-bg', css(theme.background));
    set('--ql-fg', css(theme.text));
    set('--ql-muted', css(theme.secondaryText));
    final r = theme.cornerRadius;
    set('--ql-radius', r == null ? null : '${r == r.roundToDouble() ? r.toInt() : r}px');
    if (theme.dark != null) set('color-scheme', theme.dark! ? 'dark' : 'light');
  }

  /// The web SDK's `<quranlab-sharing-settings>` in a dialog over the page, with a Done button.
  @override
  Future<void> sharingOpenSettings() async {
    final c = _c;
    final defined = web.window.customElements.get('quranlab-sharing-settings');
    if (defined == null) {
      throw const TajweedError(TajweedErrorCode.sharingUnavailable, 'The web SDK\'s sharing settings are not loaded on this page.',
          fix: 'Allow Quran Lab\'s hosts in the page\'s Content-Security-Policy (see the README), then open them again.');
    }
    final dialog = web.document.createElement('dialog') as web.HTMLDialogElement;
    dialog.style.cssText = 'max-width:480px;width:calc(100% - 32px);border:none;border-radius:var(--ql-radius,28px);'
        'padding:16px;background:var(--ql-bg,#fff);color:var(--ql-fg,#17171a)';
    final settings = web.document.createElement('quranlab-sharing-settings');
    settings.setProperty('client'.toJS, c);
    final done = web.document.createElement('button') as web.HTMLButtonElement
      ..textContent = 'Done'
      ..style.cssText = 'display:block;margin:12px 0 0 auto;padding:10px 18px;border:none;border-radius:14px;'
          'background:var(--ql-accent,#0e6b58);color:var(--ql-accent-fg,#fff);font:600 16px system-ui';
    done.onclick = ((web.Event _) => dialog.close()).toJS;
    dialog.onclose = ((web.Event _) => dialog.remove()).toJS;
    dialog
      ..appendChild(settings)
      ..appendChild(done);
    web.document.body!.appendChild(dialog);
    dialog.showModal();
  }

  @override
  Future<void> reportChecks(String rule, int checked, int flagged) =>
      _await(_call(_c.getProperty<JSObject>('analytics'.toJS), 'reportChecks', [rule.toJS, checked.toJS, flagged.toJS]));

  // ---- the output ----

  List<HeadMessage> _heads(JSObject h) {
    final out = <HeadMessage>[];
    for (final name in _strings(h.getProperty('names'.toJS))) {
      final v = h.callMethod<JSAny?>('get'.toJS, name.toJS);
      if (v == null || !v.isA<JSObject>()) continue;
      final head = v as JSObject;
      final values = head.getProperty<JSAny?>('values'.toJS);
      final f = values == null ? Float32List(0) : (values as JSFloat32Array).toDart;
      out.add(HeadMessage(
        name: name,
        kind: _str(head, 'kind') ?? 'attribute',
        frameMs: _num(head, 'frameMs') ?? 40,
        frames: _num(head, 'frames') ?? 0,
        classes: _num(head, 'classes') ?? 0,
        values: Uint8List.fromList(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes)),
      ));
    }
    return out;
  }

  DecodedRows _decoded(JSObject d) {
    final tokens = <TokenRow>[
      for (final t in _objects(d.getProperty('tokens'.toJS)))
        TokenRow(_num(t, 'id') ?? 0, _num(t, 'firstMs') ?? 0, _num(t, 'peakMs') ?? 0, _num(t, 'lastMs') ?? 0,
            _double(t, 'confidence') ?? double.nan),
    ];
    final frames = d.getProperty<JSObject>('frames'.toJS);
    final n = _num(frames, 'length') ?? 0;
    JSObject frame(int f) => frames.getProperty<JSObject>(f.toJS);
    return DecodedRows(
      tokens: tokens,
      frameCount: n,
      frame: (f) {
        final r = frame(f);
        return (
          _num(r, 'top1') ?? 0,
          _double(r, 'top1LogProb') ?? 0,
          _num(r, 'runnerUp') ?? 0,
          _double(r, 'runnerUpLogProb') ?? 0,
          _double(r, 'margin') ?? 0,
        );
      },
      rankedK: 38,
      ranked: (f, k) {
        final top = frame(f).getProperty<JSAny?>('topK'.toJS);
        if (top == null || !top.isA<JSObject>()) return (-1, double.negativeInfinity);
        final list = top as JSObject;
        if (k >= (_num(list, 'length') ?? 0)) return (-1, double.negativeInfinity);
        final e = list.getProperty<JSObject>(k.toJS);
        return (_num(e, 'id') ?? -1, _double(e, 'logProb') ?? double.negativeInfinity);
      },
      settled: _num(d, 'settled') ?? 0,
      isFinal: _bool(d, 'isFinal') ?? false,
    );
  }

  ChunkMessage _chunk(JSObject c, DeltaEncoder encoder) {
    final firstFrame = _num(c, 'firstFrame') ?? 0;
    return ChunkMessage(
      index: _num(c, 'index') ?? 0,
      startMs: _num(c, 'startMs') ?? 0,
      endMs: _num(c, 'endMs') ?? 0,
      firstFrame: firstFrame,
      backend: _backend(c.getProperty('backend'.toJS)),
      speech: _bool(c, 'speech') ?? false,
      heads: _heads(c.getProperty<JSObject>('heads'.toJS)),
      decoded: encoder.chunk(_decoded(c.getProperty<JSObject>('decoded'.toJS)), firstFrame),
    );
  }

  EventMessage _event(JSObject e) {
    final type = _str(e, 'type') ?? 'resumed';
    final err = e.getProperty<JSAny?>('error'.toJS);
    final b = e.getProperty<JSAny?>('backend'.toJS);
    return EventMessage(
      type: type,
      atMs: _num(e, 'atMs'),
      silenceMs: _num(e, 'silenceMs'),
      cause: _str(e, 'cause'),
      backend: b == null || !b.isA<JSObject>() ? null : _backend(b),
      fromChunk: _num(e, 'fromChunk'),
      reason: _str(e, 'reason'),
      error: err == null || !err.isA<JSObject>() ? null : _errorMessage(webError(err)),
    );
  }

  static ErrorMessage _errorMessage(TajweedError e) => ErrorMessage(
        code: e.code,
        message: e.message,
        fix: e.fix,
        docs: e.docs,
        cause: e.cause == null
            ? null
            : ErrorCauseMessage(
                stage: e.cause!.stage,
                reason: e.cause!.reason,
                httpStatus: e.cause!.httpStatus,
                errorName: e.cause!.errorName,
                errorCode: e.cause!.errorCode,
                needs: e.cause!.needs),
      );

  static BackendMessage _backend(JSAny? v) {
    if (v == null || !v.isA<JSObject>()) return BackendMessage(kind: 'cpu', name: 'cpu', stage: 'cpu');
    final b = v as JSObject;
    return BackendMessage(
        kind: _str(b, 'kind') ?? 'cpu', name: _str(b, 'name') ?? 'cpu', stage: _str(b, 'stage') ?? 'cpu', reason: _str(b, 'reason'));
  }
}

/// One take: its two async iterables read into the update stream, then its end.
class _WebTake {
  _WebTake(this.id, this.session, this.encoder);

  final int id;
  final JSObject session;
  final DeltaEncoder encoder;
  bool over = false;
  bool _closed = false;

  void start(WebHost host) {
    var open = 2;
    var endedSent = false;
    void end() {
      if (--open == 0) close(host);
    }

    // an iterator that rejects, or a chunk or event that cannot be read, ends the take with the SDK's error once,
    // never an uncaught error and a take with no end
    void failed(Object e) {
      if (endedSent || over) return;
      endedSent = true;
      final err = e is TajweedError
          ? e
          : TajweedError(TajweedErrorCode.engineFailed, '$e', fix: 'Send client.diagnose() with an issue to Quran Lab.');
      host._updates.add(EventUpdate(
          sessionId: id, event: EventMessage(type: 'ended', reason: 'error', error: WebHost._errorMessage(err))));
    }

    _drain(session.getProperty<JSObject>('chunks'.toJS), (JSObject c) {
      host._updates.add(ChunkUpdate(sessionId: id, chunk: host._chunk(c, encoder)));
    }).catchError(failed).whenComplete(end);
    _drain(session.getProperty<JSObject>('events'.toJS), (JSObject e) {
      final event = host._event(e);
      if (event.type == 'ended') endedSent = true;
      host._updates.add(EventUpdate(sessionId: id, event: event));
    }).catchError(failed).whenComplete(end);
  }

  void close(WebHost host) {
    over = true;
    if (_closed) return;
    _closed = true;
    host._updates.add(ClosedUpdate(sessionId: id));
  }

  /// Reads an async iterable to its end.
  static Future<void> _drain(JSObject iterable, void Function(JSObject) each) async {
    final symbol = globalContext.getProperty<JSObject>('Symbol'.toJS).getProperty<JSAny>('asyncIterator'.toJS);
    final it = iterable.callMethod<JSObject>(symbol);
    while (true) {
      final r = await _await(it.callMethod<JSPromise<JSAny?>>('next'.toJS)) as JSObject;
      if (_bool(r, 'done') ?? true) return;
      final v = r.getProperty<JSAny?>('value'.toJS);
      if (v != null && v.isA<JSObject>()) each(v as JSObject);
    }
  }
}

// ---- calling into the loader ----

/// A method of a JS object called inside a promise, so that a synchronous throw becomes a rejection: the call is
/// `Promise.resolve().then(method.bind(object, ...args))`, all in JavaScript.
JSPromise<JSAny?> _call(JSObject o, String method, [List<JSAny?> args = const []]) {
  final f = o.getProperty<JSAny?>(method.toJS);
  if (f == null || !f.isA<JSFunction>()) {
    throw TajweedError(TajweedErrorCode.runtimeUnsupported, 'The Quran Lab loader has no $method here.',
        fix: 'Update the plugin: the hosted loader is API 4.');
  }
  final bound = (f as JSFunction).callMethodVarArgs<JSFunction>('bind'.toJS, [o, ...args]);
  final resolved = globalContext.getProperty<JSObject>('Promise'.toJS).callMethod<JSObject>('resolve'.toJS);
  return resolved.callMethod<JSPromise<JSAny?>>('then'.toJS, bound);
}

/// A JS promise as a Future; a rejection is the SDK's error.
Future<JSAny?> _await(JSPromise<JSAny?> p) {
  final c = Completer<JSAny?>();
  (p as JSObject).callMethod<JSAny?>(
    'then'.toJS,
    ((JSAny? v) {
      c.complete(v);
    }).toJS,
    ((JSAny? e) {
      c.completeError(webError(e));
    }).toJS,
  );
  return c.future;
}

/// A value the web SDK threw or rejected with, as the SDK's error: its code, message, fix, docs and errorCause.
TajweedError webError(JSAny? e) {
  if (e == null || !e.isA<JSObject>()) {
    return TajweedError(TajweedErrorCode.engineFailed, '${e.dartify()}', fix: 'Send client.diagnose() with an issue to Quran Lab.');
  }
  final o = e as JSObject;
  final code = _str(o, 'code');
  final message = _str(o, 'message') ?? code ?? 'The web SDK failed.';
  if (code == null || !TajweedErrorCode.all.contains(code)) {
    return TajweedError(TajweedErrorCode.engineFailed, message, fix: 'Send client.diagnose() with an issue to Quran Lab.');
  }
  final c = o.getProperty<JSAny?>('errorCause'.toJS);
  TajweedErrorCause? cause;
  if (c != null && c.isA<JSObject>()) {
    final x = c as JSObject;
    cause = TajweedErrorCause(
      stage: _str(x, 'stage') ?? 'other',
      reason: _str(x, 'reason') ?? 'other',
      httpStatus: _num(x, 'httpStatus'),
      errorName: _str(x, 'errorName'),
      errorCode: _str(x, 'errorCode'),
      needs: _str(x, 'needs'),
    );
  }
  return TajweedError(code, message, fix: _str(o, 'fix') ?? '', docs: _str(o, 'docs'), cause: cause);
}

// ---- reading JS values ----

String? _jsString(JSAny? v) => v != null && v.isA<JSString>() ? (v as JSString).toDart : null;

int? _jsInt(JSAny? v) => v != null && v.isA<JSNumber>() ? (v as JSNumber).toDartDouble.toInt() : null;

String? _str(JSObject o, String k) => _jsString(o.getProperty<JSAny?>(k.toJS));

int? _num(JSObject o, String k) => _jsInt(o.getProperty<JSAny?>(k.toJS));

double? _double(JSObject o, String k) {
  final v = o.getProperty<JSAny?>(k.toJS);
  return v != null && v.isA<JSNumber>() ? (v as JSNumber).toDartDouble : null;
}

bool? _bool(JSObject o, String k) {
  final v = o.getProperty<JSAny?>(k.toJS);
  return v != null && v.isA<JSBoolean>() ? (v as JSBoolean).toDart : null;
}

bool _isObject(JSAny? v) => v != null && v.isA<JSObject>();

List<JSObject> _objects(JSAny? v) {
  if (v == null || !v.isA<JSObject>()) return const [];
  final a = v as JSObject;
  final n = _num(a, 'length') ?? 0;
  return [
    for (var i = 0; i < n; i++)
      if (_isObject(a.getProperty<JSAny?>(i.toJS))) a.getProperty<JSObject>(i.toJS),
  ];
}

List<String> _strings(JSAny? v) {
  if (v == null || !v.isA<JSObject>()) return const [];
  final a = v as JSObject;
  final n = _num(a, 'length') ?? 0;
  return [for (var i = 0; i < n; i++) _jsString(a.getProperty<JSAny?>(i.toJS)) ?? ''];
}

List<int> _ints(JSAny? v) {
  if (v == null || !v.isA<JSObject>()) return const [];
  final a = v as JSObject;
  final n = _num(a, 'length') ?? 0;
  return [for (var i = 0; i < n; i++) _jsInt(a.getProperty<JSAny?>(i.toJS)) ?? 0];
}

/// For tests: the JSON of a value.
String jsonOfJs(JSAny? v) => jsonEncode(v.dartify());
