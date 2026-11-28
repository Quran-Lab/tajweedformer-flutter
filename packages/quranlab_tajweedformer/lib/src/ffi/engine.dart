// The engine isolate of Windows and Linux: the one Dart isolate that holds the C SDK's Model and its Sessions (a
// Model and its Session belong to one thread at a time), so a take's blocking calls never hold up the app's UI.
// The main isolate (ffi_host.dart) sends it calls; it answers each one and sends every take's chunks, events and
// end as the same update messages the native plugins send. Internal.
//
// The C SDK calls `on_chunk` and `on_event` on the pushing thread, inside `tf_session_push`, `tf_session_finish` and
// `tf_session_listen`: here that is this isolate, so they are isolate-local callbacks that read the chunk while it is
// valid and send a copy.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../delta.dart';
import '../errors.dart';
import '../messages.g.dart';
import 'native.dart';
import 'tajweedformer.g.dart';

/// A call from the main isolate.
final class EngineCall {
  const EngineCall(this.id, this.op, this.args);
  final int id;
  final String op;
  final List<Object?> args;
}

/// The answer to one call: a value, or the SDK's error.
final class EngineReply {
  const EngineReply(this.id, this.value, this.error);
  final int id;
  final Object? value;
  final TajweedError? error;
}

/// What the engine isolate starts with: where to answer, where the libraries are, and the Client.
final class EngineStart {
  const EngineStart(this.reply, this.libraryDir, this.client);
  final SendPort reply;
  final String? libraryDir;
  final int client;
}

/// The engine isolate's entry point: answers with its own port, then serves calls until `shutdown`.
void engineMain(EngineStart start) {
  final port = ReceivePort();
  final engine = _Engine(start.reply, TfNative.open(start.libraryDir), Pointer<TfClient>.fromAddress(start.client));
  start.reply.send(port.sendPort);
  port.listen((Object? m) async {
    if (m is! EngineCall) return;
    try {
      final v = await engine.call(m.op, m.args);
      start.reply.send(EngineReply(m.id, v, null));
    } on TajweedError catch (e) {
      start.reply.send(EngineReply(m.id, null, e));
    } catch (e) {
      start.reply.send(EngineReply(m.id, null,
          TajweedError(TajweedErrorCode.engineFailed, '$e', fix: 'Send client.diagnose() with an issue to Quran Lab.')));
    }
    if (m.op == 'shutdown') port.close();
  });
}


TajweedError _pluginError(String code, String message, String fix) => TajweedError(code, message, fix: fix);

/// One take of the Dart side.
class _Take {
  _Take(this.id, this.mode, this.topK);

  final int id;
  final String mode;
  final int topK;
  late final DeltaEncoder encoder = DeltaEncoder(topK);
  Pointer<TfSession> session = nullptr;
  Pointer<TfSessionOptions> options = nullptr;
  final List<Pointer> owned = [];
  NativeCallable<Void Function(Pointer<Void>, Pointer<TfChunk>)>? onChunk;
  NativeCallable<Void Function(Pointer<Void>, Pointer<TfEvent>)>? onEvent;

  /// The take ended by itself (an `ended` event), by finish, or by cancel.
  bool ended = false;
  bool cancelled = false;
  bool closedSent = false;

  /// A clip or the samples still being fed.
  bool running = false;
  HeadsMessage? heads;
}

class _Engine {
  _Engine(this.out, this.n, this.client) {
    _adopt();
  }

  final SendPort out;
  final TfNative n;
  final Pointer<TfClient> client;
  TfBindings get tf => n.tf;

  Pointer<TfModel> model = nullptr;
  String? modelVersion;
  final Map<int, _Take> takes = {};

  /// After a hot restart: the Model that is already open is this engine's (its old engine isolate is gone and never
  /// closes it, so this engine's close is the one that closes it, and removeModels() and model(version) work after it).
  /// A take the old isolate left open is cancelled so that this engine can open takes (no callback of the old isolate
  /// runs: cancel calls none). The take is not freed: in a debug build the "old" engine can be a second Flutter engine
  /// of the same process that is still alive (a multi-window app), and freeing what it holds crashed it at its next
  /// close. A profile or release build refuses a second engine (client_exists), so such an app shares nothing.
  void _adopt() {
    final m = n.slot(TfNative.slotModel);
    if (m != 0) model = Pointer<TfModel>.fromAddress(m);
    if (model != nullptr) modelVersion = str(tf.tf_model_version(model));
    final s = n.setSlot(TfNative.slotSession, 0);
    if (s != 0) tf.tf_session_cancel(Pointer<TfSession>.fromAddress(s));
  }

  Future<Object?> call(String op, List<Object?> a) async {
    switch (op) {
      case 'model':
        return _model(a[0] as String?);
      case 'modelBackend':
        return _modelBackend();
      case 'closeModel':
        _closeModel();
        return null;
      case 'openSession':
        await _open(a[0] as int, a[1] as String, a[2] as SessionOptionsMessage, a[3] as String?, a[4] as Uint8List?,
            a[5] as int?);
        return null;
      case 'push':
        _push(a[0] as int, a[1] as Uint8List, a[2] as bool);
        return null;
      case 'finish':
        return _finish(a[0] as int);
      case 'cancel':
        _cancel(a[0] as int);
        return null;
      case 'sessionBackend':
        return _sessionBackend(a[0] as int);
      case 'reportRecited':
        _reportRecited(a[0] as int, a[1] as int, a[2] as int, a[3] as int, a[4] as RecitedOutcomeMessage?,
            (a[5] as List).cast<RecitedOutcomeMessage>());
        return null;
      case 'referenceIsDownloaded':
        return tf.tf_reference_is_downloaded(_reference()) == 1;
      case 'referenceFetch':
        n.check(tf.tf_reference_fetch(_reference()));
        return null;
      case 'referenceUnits':
        return _units(a[0] as int, a[1] as int);
      case 'shutdown':
        _closeModel();
        return null;
    }
    throw _pluginError(TajweedErrorCode.invalidArgument, 'engine: $op is not a call', 'Update the plugin.');
  }

  // ---- the model ----

  Pointer<TfModel> _open_() {
    if (model == nullptr) {
      throw _pluginError(TajweedErrorCode.invalidArgument, 'model: it is closed', 'Call client.model() again.');
    }
    return model;
  }

  ModelMessage _model(String? version) {
    if (model != nullptr && (version == null || version == modelVersion)) return _modelMessage(model);
    if (model != nullptr) _closeModel();
    final o = calloc<TfModelOptions>();
    final v = version == null ? nullptr : version.toNativeUtf8().cast<Char>();
    try {
      o.ref.version = v;
      final m = tf.tf_client_model(client, o);
      if (m == nullptr) throw n.lastError();
      model = m;
      modelVersion = str(tf.tf_model_version(m));
      n.setSlot(TfNative.slotModel, m.address);
      return _modelMessage(m);
    } finally {
      if (v != nullptr) calloc.free(v);
      calloc.free(o);
    }
  }

  ModelMessage _modelMessage(Pointer<TfModel> m) {
    final info = (jsonOf(tf.tf_model_info_json(m)) as Map?)?.cast<String, Object?>() ?? const {};
    final contexts = [...?(info['contexts'] as List?)?.whereType<String>()];
    final chunkMs = (info['chunk_ms'] as Map?)?.cast<String, Object?>() ?? const {};
    final tokens = [...?(info['tokens'] as List?)?.map((t) => '$t')];
    final wordBar = (info['word_bar'] as num?)?.toInt();
    final cal = (info['calibration'] as Map?)?.cast<String, Object?>();
    final calJson = str(tf.tf_model_calibration_json(m));
    final b = calloc<TfBackend>();
    try {
      tf.tf_model_backend(m, b);
      return ModelMessage(
        id: str(tf.tf_model_id(m)) ?? info['id'] as String? ?? '',
        version: str(tf.tf_model_version(m)) ?? info['version'] as String? ?? '',
        build: str(tf.tf_model_build(m)) ?? info['build'] as String? ?? '',
        contexts: contexts,
        chunkMs: [for (final c in contexts) (chunkMs[c] as num?)?.toInt() ?? 0],
        defaultContext: info['default_context'] as String? ?? (contexts.isEmpty ? '' : contexts.first),
        tokens: TokensMessage(
            names: tokens,
            blank: (info['blank'] as num?)?.toInt() ?? 0,
            wordBar: wordBar == null || wordBar < 0 ? null : wordBar),
        calibration: calJson == null ? null : CalibrationMessage(json: calJson, sha256: cal?['sha256'] as String? ?? ''),
        hasReference: info['reference'] == true,
        sampleClips: [
          for (final c in (info['sample_clips'] as List?) ?? const [])
            if (c is Map)
              ClipMessage(
                  name: '${c['name']}', kind: '${c['kind'] ?? 'clean'}', durationMs: (c['duration_ms'] as num?)?.toInt() ?? 0),
        ],
        backend: n.backend(b.ref),
      );
    } finally {
      calloc.free(b);
    }
  }

  BackendMessage _modelBackend() {
    final b = calloc<TfBackend>();
    try {
      n.check(tf.tf_model_backend(_open_(), b));
      return n.backend(b.ref);
    } finally {
      calloc.free(b);
    }
  }

  void _closeModel() {
    for (final t in takes.values.toList()) {
      _destroy(t, cancel: true);
    }
    takes.clear();
    if (model != nullptr) {
      n.setSlot(TfNative.slotModel, 0);
      tf.tf_model_close(model);
      model = nullptr;
      modelVersion = null;
    }
  }

  Pointer<TfReference> _reference() {
    final r = tf.tf_model_reference(_open_());
    if (r == nullptr) {
      throw _pluginError(TajweedErrorCode.referenceMissing, 'This model build ships no reference data.',
          'Check model.reference before using it.');
    }
    return r;
  }

  UnitsMessage _units(int surah, int ayah) {
    final u = calloc<TfUnits>();
    try {
      n.check(tf.tf_reference_units(_reference(), surah, ayah, u));
      final r = u.ref;
      final ids = Int32List(r.n);
      final starts = <int>[];
      for (var k = 0; k < r.n; k++) {
        ids[k] = r.ids[k];
        // the first unit of each word (a word bar belongs to the word before it)
        if (starts.length < r.n_words && r.word[k] == starts.length) starts.add(k);
      }
      return UnitsMessage(units: ids, wordStarts: Int32List.fromList(starts));
    } finally {
      calloc.free(u);
    }
  }

  // ---- takes ----

  _Take _take(int id) {
    final t = takes[id];
    if (t == null) {
      throw _pluginError(TajweedErrorCode.sessionClosed, 'This take is over.',
          'Start a new take with model.session() or model.listenFrom().');
    }
    return t;
  }

  Future<void> _open(int id, String mode, SessionOptionsMessage o, String? clipName, Uint8List? samples,
      int? sampleRate) async {
    final m = _open_();
    if (mode == 'listen') {
      throw _pluginError(TajweedErrorCode.runtimeUnsupported,
          'model.listen() has no microphone on Windows and Linux: the C SDK takes audio the app captures.',
          'Use TajweedRecorder of quranlab_tajweedformer_record (the record package\'s microphone), or capture the audio '
              'yourself and push it into model.session().');
    }
    if (mode != 'clip' && mode != 'samples' && mode != 'push') {
      throw _pluginError(TajweedErrorCode.invalidArgument, 'mode: $mode is not listen, clip, samples or push', 'Update the plugin.');
    }
    // a model has one take at a time: the takes that are over make room (an open one is the SDK's session_open). A
    // take that ended by itself keeps its session until finish() reads its heads, as on Android and iOS (an ended
    // session does not block the next one); only the newest such take is kept
    final over = [for (final t in takes.values) if (t.ended || t.cancelled) t];
    _Take? unread;
    for (final t in over) {
      if (!t.cancelled && t.heads == null && t.session != nullptr && (unread == null || t.id > unread.id)) unread = t;
    }
    for (final t in over) {
      if (identical(t, unread)) continue;
      _destroy(t);
      takes.remove(t.id);
    }
    final t = _Take(id, mode, o.topK);
    final opts = t.options = calloc<TfSessionOptions>();
    Pointer<Char> own(String s) {
      final p = s.toNativeUtf8().cast<Char>();
      t.owned.add(p);
      return p;
    }

    final r = opts.ref;
    r.context = o.context == null ? nullptr : own(o.context!);
    r.sample_rate = switch (mode) { 'clip' => 0, 'samples' => sampleRate ?? 16000, _ => o.sampleRate };
    final h = o.heads;
    r.heads = h == null ? nullptr : own(h.length == 1 && h[0] == 'all' ? 'all' : h.join(','));
    // the C SDK has the CPU engine only: auto and the compact CoreML build are both its CPU engine
    r.backend = own(o.backend == 'cpu' ? 'cpu' : 'auto');
    r.top_k = o.topK;
    r.end_on_silence_ms = o.endOnSilenceMs ?? 0;
    r.pace = o.pace == 'fast' ? TF_PACE_FAST : TF_PACE_REAL_TIME;
    final user = Pointer<Void>.fromAddress(id);
    t.onChunk = NativeCallable<Void Function(Pointer<Void>, Pointer<TfChunk>)>.isolateLocal(_onChunk);
    t.onEvent = NativeCallable<Void Function(Pointer<Void>, Pointer<TfEvent>)>.isolateLocal(_onEvent);
    r.on_chunk = t.onChunk!.nativeFunction;
    r.on_event = t.onEvent!.nativeFunction;
    r.user = user;
    takes[id] = t;
    try {
      switch (mode) {
        case 'push':
          t.session = tf.tf_session_create(m, opts);
          if (t.session == nullptr) throw n.lastError();
          n.setSlot(TfNative.slotSession, t.session.address);
        case 'clip':
          final clip = _clip(m, clipName);
          t.running = true;
          // the clip runs once the call has answered, as on the other platforms (the take starts at once)
          Timer.run(() => _runClip(t, clip));
        case 'samples':
          if (samples == null) {
            throw _pluginError(TajweedErrorCode.invalidArgument, 'samples: none were given', 'Pass the samples to listen to.');
          }
          t.session = tf.tf_session_create(m, opts);
          if (t.session == nullptr) throw n.lastError();
          n.setSlot(TfNative.slotSession, t.session.address);
          t.running = true;
          Timer.run(() => _feed(t, samples, sampleRate ?? 16000, fast: o.pace == 'fast'));
      }
    } catch (_) {
      takes.remove(id);
      _destroy(t);
      rethrow;
    }
  }

  Pointer<TfClip> _clip(Pointer<TfModel> m, String? name) {
    final count = tf.tf_model_sample_clip_count(m);
    final c = calloc<TfClip>();
    for (var i = 0; i < count; i++) {
      if (tf.tf_model_sample_clip(m, i, c) == 0 && str(c.ref.name) == name) return c;
    }
    calloc.free(c);
    throw _pluginError(
        TajweedErrorCode.invalidArgument, 'clip: ${name ?? 'null'} is not one of model.sampleClips', 'Pass one of model.sampleClips.');
  }

  /// A sample clip through `tf_session_listen`, which runs it to its end on this thread.
  void _runClip(_Take t, Pointer<TfClip> clip) {
    try {
      if (t.cancelled) return;
      final s = tf.tf_session_listen(model, clip, t.options);
      if (s == nullptr && !t.ended) {
        // the SDK sends ended(error) through on_event before it returns NULL: only a failure it did not send is sent
        final e = n.lastError();
        _send(EventUpdate(sessionId: t.id, event: EventMessage(type: 'ended', reason: 'error', error: _errorMessage(e))));
      } else {
        t.session = s;
      }
      t.ended = true;
    } finally {
      calloc.free(clip);
      t.running = false;
      _closed(t);
    }
  }

  /// `listenFromSamples`: the samples pushed into a take (as fast as the engine takes them, or at the microphone's
  /// pace), then its end, which the plugin reports as `sourceEnd` as the other platforms' SDKs do.
  Future<void> _feed(_Take t, Uint8List bytes, int rate, {required bool fast}) async {
    final all = bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    final block = fast ? rate : rate ~/ 10;
    final started = DateTime.now();
    var at = 0;
    try {
      while (at < all.length && !t.ended && !t.cancelled) {
        final end = at + block < all.length ? at + block : all.length;
        final p = calloc<Float>(end - at);
        p.asTypedList(end - at).setAll(0, all.sublist(at, end));
        final rc = tf.tf_session_push(t.session, p, end - at);
        calloc.free(p);
        if (rc < 0) {
          if (!t.ended && !t.cancelled) {
            final e = n.lastError();
            _send(EventUpdate(sessionId: t.id, event: EventMessage(type: 'ended', reason: 'error', error: _errorMessage(e))));
            t.ended = true;
          }
          break;
        }
        at = end;
        if (fast) {
          await Future<void>.delayed(Duration.zero);
        } else {
          final due = started.add(Duration(microseconds: at * 1000000 ~/ rate));
          final wait = due.difference(DateTime.now());
          await Future<void>.delayed(wait.isNegative ? Duration.zero : wait);
        }
      }
      if (!t.ended && !t.cancelled) {
        if (tf.tf_session_finish(t.session) < 0) {
          final e = n.lastError();
          _send(EventUpdate(sessionId: t.id, event: EventMessage(type: 'ended', reason: 'error', error: _errorMessage(e))));
        } else {
          _send(EventUpdate(sessionId: t.id, event: EventMessage(type: 'ended', reason: 'sourceEnd')));
        }
        t.ended = true;
      }
    } finally {
      t.running = false;
      _closed(t);
    }
  }

  void _push(int id, Uint8List pcm, bool int16) {
    final t = _take(id);
    if (t.ended || t.cancelled) {
      throw _pluginError(TajweedErrorCode.sessionClosed, 'This take is over.', 'Start a new take with model.session().');
    }
    final count = sampleCount(pcm, int16);
    if (count == 0) return;
    final p = samplesOf(pcm, int16);
    try {
      final rc = tf.tf_session_push(t.session, p, count);
      if (rc < 0) throw n.lastError();
    } finally {
      calloc.free(p);
      // the take ended by itself during this push (silence, the 20 minute limit, an error)
      if (t.ended) _closed(t);
    }
  }

  Future<HeadsMessage> _finish(int id) async {
    final t = _take(id);
    // a clip or samples still being fed: their take ends by itself first
    while (t.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (t.cancelled) {
      throw TajweedError(TajweedErrorCode.cancelled, 'The take was cancelled.', fix: str(tf.tf_error_fix(-21)) ?? '');
    }
    final done = t.heads;
    if (done != null) return done;
    if (t.session == nullptr) {
      throw _pluginError(TajweedErrorCode.sessionClosed, 'This take ended without heads.', 'Start a new take.');
    }
    if (!t.ended) {
      final rc = tf.tf_session_finish(t.session);
      if (rc < 0) throw n.lastError();
      t.ended = true;
    }
    final h = tf.tf_session_heads(t.session);
    if (h == nullptr) throw n.lastError(fallbackCode: TajweedErrorCode.sessionClosed);
    final heads = HeadsMessage(heads: n.heads(h), decoded: t.encoder.whole(n.decoded(tf.tf_heads_decoded(h))));
    t.heads = heads;
    _closed(t);
    return heads;
  }

  void _cancel(int id) {
    final t = takes[id];
    if (t == null || t.cancelled) return;
    t.cancelled = true;
    if (t.session != nullptr && !t.ended) tf.tf_session_cancel(t.session);
    t.ended = true;
    if (!t.running) _closed(t);
  }

  BackendMessage _sessionBackend(int id) {
    final t = _take(id);
    final b = calloc<TfBackend>();
    try {
      if (t.session == nullptr) return _modelBackend();
      n.check(tf.tf_session_backend(t.session, b));
      return n.backend(b.ref);
    } finally {
      calloc.free(b);
    }
  }

  void _reportRecited(int id, int surah, int from, int to, RecitedOutcomeMessage? outcome, List<RecitedOutcomeMessage> perAyah) {
    final t = _take(id);
    if (t.session == nullptr) {
      throw _pluginError(TajweedErrorCode.sessionClosed, 'This take has not started yet.', 'Report it once the take ran.');
    }
    final arena = Arena();
    try {
      void fill(TfRecitedOutcome o, RecitedOutcomeMessage m) {
        o.correct = m.correct ? 1 : 0;
        o.mistakes = m.mistakes ?? 0;
        o.n_rules = m.rules.length;
        if (m.rules.isEmpty) {
          o.rules = nullptr;
        } else {
          final rules = arena<Pointer<Char>>(m.rules.length);
          for (var i = 0; i < m.rules.length; i++) {
            rules[i] = m.rules[i].toNativeUtf8(allocator: arena).cast<Char>();
          }
          o.rules = rules;
        }
      }

      Pointer<TfRecitedOutcome> whole = nullptr;
      if (outcome != null) {
        whole = arena<TfRecitedOutcome>();
        fill(whole.ref, outcome);
      }
      Pointer<TfRecitedAyah> per = nullptr;
      if (perAyah.isNotEmpty) {
        per = arena<TfRecitedAyah>(perAyah.length);
        for (var i = 0; i < perAyah.length; i++) {
          final a = perAyah[i].ayah;
          if (a == null) {
            throw _pluginError(TajweedErrorCode.invalidArgument, 'Invalid argument: perAyah: an entry names no ayah.',
                'Name the ayah of every per-ayah outcome.');
          }
          per[i].ayah = a;
          fill(per[i].outcome, perAyah[i]);
        }
      }
      n.check(tf.tf_session_report_recited_outcome(t.session, surah, from, to, whole, per, perAyah.length));
    } finally {
      arena.releaseAll();
    }
  }

  // ---- the C SDK's callbacks, on this thread ----

  void _onChunk(Pointer<Void> user, Pointer<TfChunk> p) {
    final t = takes[user.address];
    if (t == null || t.cancelled) return;
    try {
      _chunk(t, p);
    } catch (e, st) {
      _callbackFailed(t, e, st);
    }
  }

  void _chunk(_Take t, Pointer<TfChunk> p) {
    final c = p.ref;
    final chunk = ChunkMessage(
      index: c.index,
      startMs: c.start_ms,
      endMs: c.end_ms,
      firstFrame: c.first_frame,
      backend: n.backend(c.backend),
      speech: c.speech != 0,
      heads: n.heads(c.heads),
      decoded: t.encoder.chunk(n.decoded(c.decoded), c.first_frame),
    );
    _send(ChunkUpdate(sessionId: t.id, chunk: chunk));
  }

  void _onEvent(Pointer<Void> user, Pointer<TfEvent> p) {
    final t = takes[user.address];
    if (t == null || t.cancelled) return;
    try {
      final e = n.event(p.ref);
      if (e.type == 'ended') t.ended = true;
      _send(EventUpdate(sessionId: t.id, event: e));
    } catch (e, st) {
      _callbackFailed(t, e, st);
    }
  }

  /// A chunk or an event that could not be read (a fault of the plugin): the take is told, never left waiting.
  void _callbackFailed(_Take t, Object e, StackTrace st) {
    _send(EventUpdate(
        sessionId: t.id,
        event: EventMessage(
            type: 'ended',
            reason: 'error',
            error: ErrorMessage(
                code: TajweedErrorCode.engineFailed,
                message: "The plugin could not read the C SDK's output: $e",
                fix: 'Send client.diagnose() and this message with an issue to Quran Lab.',
                docs: 'https://sdk.quranlab.ai/docs/errors#engine_failed'))));
    // ignore: avoid_print
    print('quranlab_tajweedformer: $e $st');
  }

  // ---- helpers ----

  void _send(UpdateMessage u) => out.send(u);

  /// The take's two streams end (once).
  void _closed(_Take t) {
    if (t.closedSent) return;
    t.closedSent = true;
    // the slot is cleared when the session is destroyed (_destroy), so a hot restart still frees an ended one
    _send(ClosedUpdate(sessionId: t.id));
  }

  void _destroy(_Take t, {bool cancel = false}) {
    if (t.session != nullptr) {
      if (cancel && !t.ended) tf.tf_session_cancel(t.session);
      if (n.slot(TfNative.slotSession) == t.session.address) n.setSlot(TfNative.slotSession, 0);
      tf.tf_session_destroy(t.session);
      t.session = nullptr;
    }
    if (cancel && !t.closedSent) {
      t.cancelled = true;
      _closed(t);
    }
    t.onChunk?.close();
    t.onEvent?.close();
    t.onChunk = null;
    t.onEvent = null;
    for (final p in t.owned) {
      calloc.free(p);
    }
    t.owned.clear();
    if (t.options != nullptr) {
      calloc.free(t.options);
      t.options = nullptr;
    }
  }

  ErrorMessage _errorMessage(TajweedError e) => ErrorMessage(
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
}
