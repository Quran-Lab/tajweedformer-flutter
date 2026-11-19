// The Dart end of the platform channels: one host API, one stream of updates for every take and download,
// and the conversions from the wire messages (messages.g.dart) to the public types. Internal.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'errors.dart';
import 'messages.g.dart';
import 'output.dart';

/// What a take's session registers to receive its updates.
abstract interface class UpdateSink {
  void chunk(ChunkMessage m);
  void event(EventMessage m);
  void closed();
}

class Bridge {
  Bridge._();

  /// The one bridge of the isolate. Tests replace nothing here: they answer the channels themselves.
  static final Bridge instance = Bridge._();

  final TajweedHostApi api = TajweedHostApi();
  StreamSubscription<UpdateMessage>? _updates;
  final Map<int, UpdateSink> _sessions = {};
  final Map<int, void Function(int done, int total)> _progress = {};
  int _nextId = 1;

  /// A fresh id for a take or a download's progress, unique in this isolate.
  int nextId() => _nextId++;

  void _listen() {
    _updates ??= updates().listen(_on, onError: (Object _) {
      // a broken stream is not the takes' failure: their calls report their own errors
    }, onDone: () => _updates = null);
  }

  void _on(UpdateMessage u) {
    switch (u) {
      case ChunkUpdate():
        _sessions[u.sessionId]?.chunk(u.chunk);
      case EventUpdate():
        _sessions[u.sessionId]?.event(u.event);
      case ClosedUpdate():
        _sessions.remove(u.sessionId)?.closed();
      case ProgressUpdate():
        _progress[u.callId]?.call(u.done, u.total);
    }
  }

  void register(int id, UpdateSink sink) {
    _listen();
    _sessions[id] = sink;
  }

  void unregister(int id) => _sessions.remove(id);

  /// A progress id for one call, or null without a callback; [done] forgets it.
  int? progress(void Function(int done, int total)? onProgress) {
    if (onProgress == null) return null;
    _listen();
    final id = nextId();
    _progress[id] = onProgress;
    return id;
  }

  void done(int? progressId) {
    if (progressId != null) _progress.remove(progressId);
  }
}

// ---- the wire to the public types ----

TajweedBackend backendOf(BackendMessage m) => TajweedBackend(
      kind: m.kind == 'accelerator' ? TajweedBackendKind.accelerator : TajweedBackendKind.cpu,
      name: m.name,
      stage: TajweedBackendStage.values.firstWhere((s) => s.name == m.stage, orElse: () => TajweedBackendStage.cpu),
      reason: m.reason,
    );

TajweedError errorOf(ErrorMessage m) => TajweedError(m.code, m.message, fix: m.fix, docs: m.docs);

TajweedEvent eventOf(EventMessage m) {
  switch (m.type) {
    case 'speechStarted':
      return TajweedSpeechStarted(m.atMs ?? 0);
    case 'speechEnded':
      return TajweedSpeechEnded(m.atMs ?? 0, m.silenceMs ?? 0);
    case 'interrupted':
      return TajweedInterrupted(
          m.cause == 'routeChange' ? TajweedInterruptionCause.routeChange : TajweedInterruptionCause.interruption);
    case 'resumed':
      return const TajweedResumed();
    case 'backendChanged':
      return TajweedBackendChanged(
          backendOf(m.backend ?? BackendMessage(kind: 'cpu', name: 'cpu', stage: 'cpu')), m.fromChunk ?? 0);
    default:
      final reason =
          TajweedEndReason.values.firstWhere((r) => r.name == m.reason, orElse: () => TajweedEndReason.error);
      return TajweedEnded(reason, m.error == null ? null : errorOf(m.error!));
  }
}

/// float32 little-endian bytes as a Float32List, without a copy when the bytes are aligned.
Float32List floatsOf(Uint8List bytes) {
  if (bytes.offsetInBytes % 4 == 0) return bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.lengthInBytes ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getFloat32(i * 4, Endian.little);
  }
  return out;
}

/// Samples as the bytes the native side reads (float32 or int16, little endian; every phone is little endian).
Uint8List bytesOfFloats(Float32List samples) => samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);

Uint8List bytesOfInt16(Int16List samples) => samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);

TajweedHead headOf(HeadMessage m) => TajweedHead(
      name: m.name,
      kind: m.kind == 'ctc' ? TajweedHeadKind.ctc : TajweedHeadKind.attribute,
      frameMs: m.frameMs,
      frames: m.frames,
      classes: m.classes,
      values: floatsOf(m.values),
      classNames: m.classNames == null ? null : List.unmodifiable(m.classNames!),
    );

/// The decoded layer of one take, rebuilt from the deltas the native side sends: the tokens and frames from
/// `tokenStart` and `frameStart` on replace what is held. Each [TajweedDecoded] handed out keeps its own view:
/// a later chunk never changes a decoded layer the app already has.
class DecodedState {
  DecodedState(this.names, this.wordBar);

  final List<String> names;
  final int? wordBar;
  List<TajweedToken> _tokens = const [];
  List<TajweedFrame> _frames = <TajweedFrame>[];

  TajweedDecoded apply(DecodedMessage m) {
    _tokens = [..._tokens.take(m.tokenStart.clamp(0, _tokens.length)), ...tokensOf(m)];
    if (m.frameStart < _frames.length) {
      // a replay (the backend changed): the frames held from there on are replaced; older views keep theirs
      _frames = _frames.sublist(0, m.frameStart.clamp(0, _frames.length));
    }
    _frames.addAll(framesOf(m));
    return TajweedDecoded(
      tokens: _tokens,
      frames: _PrefixView(_frames, _frames.length),
      settled: m.settled,
      isFinal: m.isFinal,
      wordBar: wordBar,
    );
  }

  List<TajweedToken> tokensOf(DecodedMessage m) => [
        for (var i = 0; i < m.tokenIds.length; i++)
          TajweedToken(
            id: m.tokenIds[i],
            name: m.tokenIds[i] >= 0 && m.tokenIds[i] < names.length ? names[m.tokenIds[i]] : '?',
            firstMs: m.tokenFirstMs[i],
            peakMs: m.tokenPeakMs[i],
            lastMs: m.tokenLastMs[i],
            confidence: m.tokenConfidence[i].isNaN ? null : m.tokenConfidence[i],
          ),
      ];

  static List<TajweedFrame> framesOf(DecodedMessage m) {
    final k = m.topK;
    return [
      for (var i = 0; i < m.frameTop.length; i++)
        TajweedFrame(
          index: m.frameStart + i,
          top: m.frameTop[i],
          topLogProb: m.frameTopLogProb[i],
          runnerUp: m.frameRunnerUp[i],
          runnerUpLogProb: m.frameRunnerUpLogProb[i],
          margin: m.frameMargin[i],
          topK: k == 0 ? const [] : List.unmodifiable(m.frameTopK.sublist(i * k, (i + 1) * k)),
          topKLogProbs: k == 0 ? const [] : List.unmodifiable(m.frameTopKLogProbs.sublist(i * k, (i + 1) * k)),
        ),
    ];
  }

  /// A whole decoded layer (the one `finish()` returns), without the take's held state.
  TajweedDecoded whole(DecodedMessage m) => TajweedDecoded(
        tokens: tokensOf(m),
        frames: framesOf(m),
        settled: m.settled,
        isFinal: m.isFinal,
        wordBar: wordBar,
      );
}

/// The first [length] elements of a list that only grows: a fixed, read-only view.
class _PrefixView<T> extends ListBase<T> {
  _PrefixView(this._list, this._length);
  final List<T> _list;
  final int _length;

  @override
  int get length => _length;

  @override
  set length(int _) => throw UnsupportedError('read-only');

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _list[index];
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('read-only');
}

/// A single-subscription stream that keeps at most [limit] items while nobody reads, dropping the oldest ones
/// first (never one that [keep] marks), as the native SDKs bound what waits for the app.
class BoundedStream<T> {
  BoundedStream(this.limit, {this.keep}) {
    _c = StreamController<T>(onListen: _flush, onResume: _flush);
  }

  final int limit;
  final bool Function(T)? keep;
  late final StreamController<T> _c;
  final ListQueue<T> _waiting = ListQueue<T>();
  int dropped = 0;
  bool _closed = false;

  Stream<T> get stream => _c.stream;

  bool get _flowing => _c.hasListener && !_c.isPaused;

  void add(T item) {
    if (_closed) return;
    if (_flowing && _waiting.isEmpty) {
      _c.add(item);
      return;
    }
    _waiting.add(item);
    while (_waiting.length > limit) {
      final drop = _waiting.firstWhere((e) => keep == null || !keep!(e), orElse: () => _waiting.first);
      _waiting.remove(drop);
      dropped++;
    }
    _flush();
  }

  void _flush() {
    while (_waiting.isNotEmpty && _flowing) {
      _c.add(_waiting.removeFirst());
    }
    if (_closed && _waiting.isEmpty && !_c.isClosed) _c.close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _flush();
    if (_waiting.isEmpty && !_c.isClosed) _c.close();
  }
}
