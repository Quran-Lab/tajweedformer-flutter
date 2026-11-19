import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'errors.dart';

/// What ran or will run the model: the CPU engine or the device's accelerator build (the Neural Engine on iOS,
/// an NPU on some Android phones), and where that accelerator's promotion stands.
class TajweedBackend {
  const TajweedBackend({required this.kind, required this.name, required this.stage, this.reason});

  final TajweedBackendKind kind;

  /// `cpu`, `coreml`, `coreml-compact`, or the name of an NPU build.
  final String name;
  final TajweedBackendStage stage;

  /// The stable reason code of a failed or demoted promotion (`golden_mismatch`, `compile_error`, ...), else null.
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is TajweedBackend && other.kind == kind && other.name == name && other.stage == stage && other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, name, stage, reason);

  @override
  String toString() => 'TajweedBackend(${kind.name}, $name, ${stage.name}${reason == null ? '' : ', $reason'})';
}

enum TajweedBackendKind {
  /// The exact CPU engine: the same bits on every device.
  cpu,

  /// The Neural Engine's CoreML build (iOS) or an NPU build (Android).
  accelerator,
}

enum TajweedBackendStage {
  /// No accelerator here, or its promotion has not started.
  cpu,
  downloading,
  compiling,
  testing,

  /// The accelerator's build passed its test: takes run on it.
  promoted,

  /// The build failed a stage or a take and is set aside; the CPU engine serves.
  demoted,
}

/// One chunk of a take as it streams (every 320 ms at the default context).
class TajweedChunk {
  const TajweedChunk({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.firstFrame,
    required this.backend,
    required this.speech,
    required this.heads,
    required this.decoded,
  });

  /// The chunk's number in the take, from 0. After a [TajweedBackendChanged] event the chunks from its
  /// `fromChunk` on come again with the same indexes: replace what you kept for them.
  final int index;
  final int startMs;
  final int endMs;

  /// The chunk's first 40 ms frame in the take.
  final int firstFrame;

  /// The backend that ran it.
  final TajweedBackend backend;

  /// Whether the model heard speech in this chunk, from its own output (not the signal's level).
  final bool speech;

  /// The heads of this chunk only.
  final TajweedHeads heads;

  /// The decoded layer of the take so far.
  final TajweedDecoded decoded;
}

/// The decoded layer: what the model heard in the take so far, ready to show. No known text is involved.
class TajweedDecoded {
  TajweedDecoded({
    required List<TajweedToken> tokens,
    required List<TajweedFrame> frames,
    required this.settled,
    required this.isFinal,
    required int? wordBar,
  })  : tokens = UnmodifiableListView(tokens),
        frames = UnmodifiableListView(frames),
        _wordBar = wordBar;

  /// The tokens heard, in order (the word bar included, as in the native SDKs).
  final List<TajweedToken> tokens;

  /// Per 40 ms frame of `log_probs`: the top token, the runner-up and their margin.
  final List<TajweedFrame> frames;

  /// How many leading tokens will not change any more in this take. Draw them once and redraw only the tail.
  final int settled;

  /// True on the take's last chunk, and on the decoded layer of a finished take.
  final bool isFinal;

  final int? _wordBar;

  /// The token names joined by single spaces.
  late final String text = tokens.map((t) => t.name).join(' ');

  /// The tokens between word bars.
  late final List<TajweedWord> words = _words();

  List<TajweedWord> _words() {
    final out = <TajweedWord>[];
    var cur = <TajweedToken>[];
    for (final t in tokens) {
      if (_wordBar != null && t.id == _wordBar) {
        if (cur.isNotEmpty) out.add(TajweedWord._(out.length, cur));
        cur = <TajweedToken>[];
      } else {
        cur.add(t);
      }
    }
    if (cur.isNotEmpty) out.add(TajweedWord._(out.length, cur));
    return UnmodifiableListView(out);
  }
}

/// A token the model heard: a run of frames with the same non-blank top token.
class TajweedToken {
  const TajweedToken({
    required this.id,
    required this.name,
    required this.firstMs,
    required this.peakMs,
    required this.lastMs,
    required this.confidence,
  });

  final int id;

  /// The token's name in the model's vocabulary.
  final String name;

  /// The start of the run's first frame, of its strongest frame and of its last frame, in ms of the take.
  final int firstMs;
  final int peakMs;
  final int lastMs;

  /// The mean of the `conf` head over the run, 0 to 1; null where the SDK has none.
  final double? confidence;

  @override
  bool operator ==(Object other) =>
      other is TajweedToken &&
      other.id == id &&
      other.firstMs == firstMs &&
      other.peakMs == peakMs &&
      other.lastMs == lastMs &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(id, firstMs, peakMs, lastMs, confidence);

  @override
  String toString() => '$name@$firstMs';
}

/// The tokens between two word bars.
class TajweedWord {
  TajweedWord._(this.index, List<TajweedToken> tokens) : tokens = UnmodifiableListView(tokens);

  /// Words since the take started, from 0.
  final int index;
  final List<TajweedToken> tokens;

  String get text => tokens.map((t) => t.name).join(' ');
  int get firstMs => tokens.first.firstMs;
  int get lastMs => tokens.last.lastMs;

  /// The lowest token confidence; null when a token has none.
  double? get confidence {
    double? low;
    for (final t in tokens) {
      final c = t.confidence;
      if (c == null) return null;
      if (low == null || c < low) low = c;
    }
    return low;
  }
}

/// One 40 ms frame of `log_probs`: the top token, the runner-up and their margin.
class TajweedFrame {
  const TajweedFrame({
    required this.index,
    required this.top,
    required this.topLogProb,
    required this.runnerUp,
    required this.runnerUpLogProb,
    required this.margin,
    this.topK = const [],
    this.topKLogProbs = const [],
  });

  /// The frame's index in the take; it covers `[40 * index, 40 * (index + 1))` ms.
  final int index;

  /// The best token's id (0 is the blank) and its log-probability.
  final int top;
  final double topLogProb;
  final int runnerUp;
  final double runnerUpLogProb;

  /// `topLogProb - runnerUpLogProb`.
  final double margin;

  /// With `topK` set on the session: the K best token ids of the frame, best first, and their log-probabilities.
  final List<int> topK;
  final List<double> topKLogProbs;

  int get startMs => index * 40;
}

enum TajweedHeadKind {
  /// A CTC head over the model's tokens: log-probabilities; greedy tokens apply.
  ctc,

  /// A per-frame attribute: class probabilities, or one logit (`boundary`, `conf`).
  attribute,
}

/// One raw head of the network for a span of audio: [frames] rows of [classes] values, row major.
class TajweedHead {
  const TajweedHead({
    required this.name,
    required this.kind,
    required this.frameMs,
    required this.frames,
    required this.classes,
    required this.values,
    this.classNames,
  });

  /// One of the twelve head names (`log_probs`, `inter1_log_probs`, ..., `conf`).
  final String name;
  final TajweedHeadKind kind;

  /// Milliseconds per frame: 40 or 20.
  final int frameMs;
  final int frames;

  /// Values per frame.
  final int classes;

  /// `frames * classes` values, frames first.
  final Float32List values;

  /// The names of an attribute head's classes. Android gives them; iOS does not (null there).
  final List<String>? classNames;

  double at(int frame, int cls) => values[frame * classes + cls];
}

/// The raw output of the network for a span of audio (a chunk, or the whole take from `session.finish()`).
class TajweedHeads {
  TajweedHeads(List<TajweedHead> heads, this._decoded, this._names, this._blank, this._firstFrame)
      : _heads = {for (final h in heads) h.name: h};

  /// The CTC heads (`greedy` reads only these).
  static const ctcHeads = <String>['log_probs', 'inter1_log_probs', 'inter4_log_probs', 'id_log_probs', 'timing_log_probs'];

  final Map<String, TajweedHead> _heads;
  final TajweedDecoded? _decoded;
  final List<String> _names;
  final int _blank;
  final int _firstFrame;

  /// The names of the heads it holds, in the network's order.
  List<String> get names => List.unmodifiable(_heads.keys);

  /// One head by its name; null when these heads do not hold it (it was not selected for the session).
  TajweedHead? operator [](String name) => _heads[name];

  /// The greedy tokens of a CTC head: repeats merged, the blank removed, each run with its first, strongest and
  /// last frame in ms of the take, and as confidence the sigmoid of the margin between the top token and the next
  /// one at the strongest frame (the Android SDK's definition; computed here from the head's values). Empty for a
  /// CTC head these heads do not hold; a name that is not a CTC head is `invalid_argument`.
  List<TajweedToken> greedy([String name = 'log_probs']) {
    if (!ctcHeads.contains(name)) {
      throw TajweedError(TajweedErrorCode.invalidArgument, 'head: $name is not a CTC head (${ctcHeads.join(', ')})',
          fix: 'Pass the name of a CTC head.');
    }
    final h = _heads[name];
    if (h == null || h.classes == 0) return const [];
    final w = h.classes;
    final v = h.values;
    final offset = _firstFrame * (40 ~/ h.frameMs);
    int best(int f) {
      var b = 0;
      for (var k = 1; k < w; k++) {
        if (v[f * w + k] > v[f * w + b]) b = k;
      }
      return b;
    }

    final out = <TajweedToken>[];
    var t = 0;
    while (t < h.frames) {
      final top = best(t);
      var end = t;
      while (end + 1 < h.frames && best(end + 1) == top) {
        end++;
      }
      if (top != _blank) {
        var peak = t;
        for (var f = t; f <= end; f++) {
          if (v[f * w + top] > v[peak * w + top]) peak = f;
        }
        var second = double.negativeInfinity;
        for (var k = 0; k < w; k++) {
          if (k != top && v[peak * w + k] > second) second = v[peak * w + k];
        }
        final margin = v[peak * w + top] - second;
        out.add(TajweedToken(
            id: top,
            name: top < _names.length ? _names[top] : '?',
            firstMs: (offset + t) * h.frameMs,
            peakMs: (offset + peak) * h.frameMs,
            lastMs: (offset + end) * h.frameMs,
            confidence: 1 / (1 + math.exp(-margin))));
      }
      t = end + 1;
    }
    return out;
  }

  /// The decoded layer of exactly these heads: for the take's heads from `session.finish()`, the final one.
  TajweedDecoded decoded() {
    final d = _decoded;
    if (d == null) {
      throw const TajweedError(TajweedErrorCode.invalidArgument,
          'These heads carry no decoded layer: a chunk\'s layer is chunk.decoded.',
          fix: 'Read chunk.decoded for a chunk, and heads.decoded() on the heads that session.finish() returns.');
    }
    return d;
  }
}

/// What happened to a take, on `session.events`.
sealed class TajweedEvent {
  const TajweedEvent();
}

/// The first sound of a stretch of speech.
class TajweedSpeechStarted extends TajweedEvent {
  const TajweedSpeechStarted(this.atMs);
  final int atMs;
}

/// Silence after speech: 1500 ms, or `endOnSilenceMs` when it is set (the take then finishes).
class TajweedSpeechEnded extends TajweedEvent {
  const TajweedSpeechEnded(this.atMs, this.silenceMs);
  final int atMs;
  final int silenceMs;
}

enum TajweedInterruptionCause {
  /// A call, or another app took the audio: the take is paused until [TajweedResumed].
  interruption,

  /// Headphones in or out, another input: the microphone was opened again and the take goes on.
  routeChange,
}

/// A `listen` take only: an interruption or a change of the audio route.
class TajweedInterrupted extends TajweedEvent {
  const TajweedInterrupted(this.cause);
  final TajweedInterruptionCause cause;
}

/// An interruption ended and the take goes on.
class TajweedResumed extends TajweedEvent {
  const TajweedResumed();
}

/// The take moved from the accelerator to the CPU engine. The chunks from [fromChunk] on come again and replace
/// the ones the app has.
class TajweedBackendChanged extends TajweedEvent {
  const TajweedBackendChanged(this.backend, this.fromChunk);
  final TajweedBackend backend;
  final int fromChunk;
}

enum TajweedEndReason {
  /// `endOnSilenceMs` of silence followed speech.
  silence,

  /// The app left the foreground (a `listen` take never holds the microphone in the background).
  background,

  /// The page lost visibility (the web SDK only; never here).
  hidden,

  /// An interruption that could not be resumed.
  interrupted,

  /// The clip or the samples of `listenFrom` ran out.
  sourceEnd,

  /// The take holds 20 minutes of audio, the most a take may.
  limit,

  /// A failure: see [TajweedEnded.error].
  error,
}

/// The take ended without the app's `finish()`. The last chunk has `decoded.isFinal`, `chunks` ends, and
/// `finish()` returns the take's heads.
class TajweedEnded extends TajweedEvent {
  const TajweedEnded(this.reason, [this.error]);
  final TajweedEndReason reason;
  final TajweedError? error;
}
