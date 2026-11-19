import 'dart:async';
import 'dart:typed_data';

import 'bridge.dart';
import 'errors.dart';
import 'messages.g.dart';
import 'output.dart';

/// Which engine a session may use.
enum TajweedSessionBackend {
  /// The CPU engine first, the device's accelerator build once it passed its test.
  auto,

  /// The CPU engine only.
  cpu,

  /// iOS: as [auto], with the compact CoreML build (int8 weights, a much smaller download) in place of the fp16
  /// one. Android treats it as [auto].
  coremlCompact,
}

/// `listenFrom` and `listenFromSamples` only: how fast the audio is fed.
enum TajweedPace {
  /// As fast as a microphone would give it.
  realTime,

  /// As fast as the engine takes it.
  fast,
}

/// How a session runs. Every field has a default; `TajweedSessionOptions()` is the quick start's.
class TajweedSessionOptions {
  const TajweedSessionOptions({
    this.context,
    this.sampleRate = 16000,
    this.heads,
    this.backend = TajweedSessionBackend.auto,
    this.topK = 0,
    this.endOnSilenceMs,
    this.pace = TajweedPace.realTime,
  });

  /// The model context (response time): `c8_l64` 160 ms, `c16_l64` 320 ms, `c24_*` 480 ms, and the contexts the
  /// model lists. Null: the context set for the app at sdk.quranlab.ai, else the model's default.
  final String? context;

  /// The rate of the samples the app pushes (`session()` only), 8000 to 48000. `listen` takes the microphone's.
  final int sampleRate;

  /// The heads each chunk and the take carry, by name, or [allHeads]. Null: the six of [defaultHeads].
  final List<String>? heads;
  final TajweedSessionBackend backend;

  /// How many ranked tokens each decoded frame carries (0: only the best and the runner-up; up to the token count).
  final int topK;

  /// Null or 0: off. 500 to 60000: the take finishes after that much silence following speech
  /// (`TajweedEnded(silence)`). A held sound is speech, however long. Keep a Stop button in any case.
  final int? endOnSilenceMs;
  final TajweedPace pace;

  /// The six heads a session gives when nothing else is asked for.
  static const defaultHeads = <String>['log_probs', 'inter1_log_probs', 'timing_log_probs', 'gem', 'attr_qalqalah', 'conf'];

  /// Every head of the network.
  static const allHeads = <String>[
    'log_probs', 'inter1_log_probs', 'inter4_log_probs', 'id_log_probs', 'timing_log_probs', 'gem',
    'attr_tafkheem', 'attr_ghunna', 'attr_qalqalah', 'attr_face', 'boundary', 'conf',
  ];

  SessionOptionsMessage toMessage() => SessionOptionsMessage(
        context: context,
        sampleRate: sampleRate,
        heads: heads,
        backend: switch (backend) {
          TajweedSessionBackend.auto => 'auto',
          TajweedSessionBackend.cpu => 'cpu',
          TajweedSessionBackend.coremlCompact => 'coreml-compact',
        },
        topK: topK,
        endOnSilenceMs: endOnSilenceMs,
        pace: pace.name,
      );
}

/// How the app's own judge found a recited range or ayah, for `session.reportRecited`: correct, or incorrect with an
/// optional count of mistakes and the rules they broke. The SDK never judges a recitation: it only counts what the app
/// reports, into anonymous daily totals for the app's statistics at sdk.quranlab.ai.
///
/// ```dart
/// await session.reportRecited(surah: 2, ayahFrom: 255, ayahTo: 257,
///     outcome: TajweedRecitedOutcome.incorrect(mistakes: 2, rules: ['madd', 'qalqalah']),
///     perAyah: {255: const TajweedRecitedOutcome.correct()});
/// ```
class TajweedRecitedOutcome {
  /// A correct recitation.
  const TajweedRecitedOutcome.correct()
      : isCorrect = true,
        mistakes = null,
        rules = const [];

  const TajweedRecitedOutcome._incorrect(this.mistakes, this.rules) : isCorrect = false;

  /// An incorrect recitation: [mistakes] 1 to 1000 or null; [rules] at most 8 ids of lower-case letters, digits and
  /// underscores starting with a letter, at most 24 long (the calibration's ids where they apply). Anything else is
  /// `invalid_argument`, never sent.
  factory TajweedRecitedOutcome.incorrect({int? mistakes, List<String> rules = const []}) {
    if (mistakes != null && (mistakes < 1 || mistakes > maxMistakes)) {
      throw invalidArgument('mistakes: $mistakes is not 1..$maxMistakes');
    }
    if (rules.length > maxRules) throw invalidArgument('rules: ${rules.length} rules, at most $maxRules');
    for (final r in rules) {
      if (!_rule.hasMatch(r)) throw invalidArgument(r'rules: ' '$r' r' is not a rule id (^[a-z][a-z0-9_]{0,23}$)');
    }
    return TajweedRecitedOutcome._incorrect(mistakes, List.unmodifiable(rules.toSet().toList()));
  }

  /// True for a correct recitation.
  final bool isCorrect;

  /// The mistakes the app counted, or null when it gave none. Always null for a correct one.
  final int? mistakes;

  /// The rules the mistakes broke. Empty for a correct one.
  final List<String> rules;

  static const maxMistakes = 1000;
  static const maxRules = 8;
  static final _rule = RegExp(r'^[a-z][a-z0-9_]{0,23}$');

  RecitedOutcomeMessage _message(int? ayah) =>
      RecitedOutcomeMessage(correct: isCorrect, mistakes: mistakes, rules: rules, ayah: ayah);

  @override
  bool operator ==(Object other) =>
      other is TajweedRecitedOutcome &&
      other.isCorrect == isCorrect &&
      other.mistakes == mistakes &&
      other.rules.length == rules.length &&
      Iterable<int>.generate(rules.length).every((i) => other.rules[i] == rules[i]);

  @override
  int get hashCode => Object.hash(isCorrect, mistakes, Object.hashAll(rules));

  @override
  String toString() => isCorrect ? 'correct' : 'incorrect(mistakes: $mistakes, rules: $rules)';
}

/// One take: audio in, chunks and events out, the take's heads at the end.
///
/// Made by `model.listen()` (the SDK's microphone), `model.listenFrom(clip)`, `model.listenFromSamples(...)` or
/// `model.session()` (the app pushes audio). The next take is a new session from the same model.
class TajweedSession implements UpdateSink {
  TajweedSession.internal(this._id, this._names, this._blank, int? wordBar, {required this.pushes})
      : _decoded = DecodedState(_names, wordBar);

  final int _id;
  final List<String> _names;
  final int _blank;
  final DecodedState _decoded;

  /// Whether the app feeds this session (`model.session()`).
  final bool pushes;

  final BoundedStream<TajweedChunk> _chunks = BoundedStream<TajweedChunk>(256, keep: (c) => c.decoded.isFinal);
  final BoundedStream<TajweedEvent> _events = BoundedStream<TajweedEvent>(64, keep: (e) => e is TajweedEnded);
  bool _over = false;

  Bridge get _bridge => Bridge.instance;

  /// Each chunk as it is ready; ends when the take ends. At most 256 wait to be read: when the app reads late, the
  /// oldest are dropped (each chunk's `decoded` is the take so far, and `finish()` returns the whole take).
  Stream<TajweedChunk> get chunks => _chunks.stream;

  /// What happened to the take; ends with it. At most 64 wait; the oldest are dropped, never `TajweedEnded`.
  Stream<TajweedEvent> get events => _events.stream;

  /// Chunks dropped because nobody read [chunks] in time.
  int get droppedChunks => _chunks.dropped;

  /// Audio in: mono float samples in -1..1 at the options' `sampleRate`. Only on a session from
  /// `model.session()`; otherwise, or after the take ended, `session_closed`. Pushes keep their order; the
  /// returned future completes once the engine has taken the samples.
  Future<void> push(Float32List samples) => _push(bytesOfFloats(samples), false);

  /// The same as [push] for signed 16-bit samples.
  Future<void> pushInt16(Int16List samples) => _push(bytesOfInt16(samples), true);

  /// The pushes of a take go to the native side one after another, so they reach the engine in the order the app
  /// made them whatever the platform's threads do. The samples are copied now: the app may reuse its buffer.
  Future<void> _push(Uint8List bytes, bool int16) {
    if (!pushes) {
      return Future.error(const TajweedError(TajweedErrorCode.sessionClosed, 'This session takes no pushed audio.',
          fix: 'Push audio only into a session from model.session(); listen sessions feed themselves.'));
    }
    final copy = Uint8List.fromList(bytes);
    final before = _lastPush;
    final next = () async {
      await before;
      await guarded(() => _bridge.api.push(_id, copy, int16));
    }();
    _lastPush = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _lastPush = Future<void>.value();

  /// Ends the take and returns its heads: every selected head over the whole take, and its final decoded layer
  /// (`heads.decoded()`). On a `listen` session it also stops the microphone. After a take that ended by itself
  /// it returns that take's heads; after [cancel] it fails with `cancelled`. Pushes made before it are taken first.
  Future<TajweedHeads> finish() => guarded(() async {
        await _lastPush;
        final m = await _bridge.api.finish(_id);
        final decoded = _decoded.whole(m.decoded);
        return TajweedHeads([for (final h in m.heads) headOf(h)], decoded, _names, _blank, 0);
      });

  /// Ends the take and keeps nothing.
  Future<void> cancel() => guarded(() => _bridge.api.cancel(_id));

  /// The backend in force for this take.
  Future<TajweedBackend> backend() => guarded(() async => backendOf(await _bridge.api.sessionBackend(_id)));

  /// Where the learner recited in this take, for the app's statistics at sdk.quranlab.ai. The native SDK places each
  /// take in the Quran by itself and counts its ayahs; this report is the fallback, used only for a take it could not
  /// place, so a take is never counted twice. One report per take.
  ///
  /// When the app judged the recitation, [outcome] says how for the whole range and [perAyah] for single ayahs of it
  /// (they win over [outcome] for those ayahs). The SDK counts them as the app's own judgement; it never judges a
  /// recitation itself. A surah or ayah the Quran does not have, or an ayah of [perAyah] outside the range, is
  /// `invalid_argument`.
  Future<void> reportRecited({
    required int surah,
    required int ayahFrom,
    required int ayahTo,
    TajweedRecitedOutcome? outcome,
    Map<int, TajweedRecitedOutcome> perAyah = const {},
  }) =>
      guarded(() => _bridge.api.reportRecited(_id, surah, ayahFrom, ayahTo, outcome?._message(null),
          [for (final e in perAyah.entries) e.value._message(e.key)]));

  // ---- updates from the native side ----

  @override
  void chunk(ChunkMessage m) {
    if (_over) return;
    final decoded = _decoded.apply(m.decoded);
    _chunks.add(TajweedChunk(
      index: m.index,
      startMs: m.startMs,
      endMs: m.endMs,
      firstFrame: m.firstFrame,
      backend: backendOf(m.backend),
      speech: m.speech,
      heads: TajweedHeads([for (final h in m.heads) headOf(h)], null, _names, _blank, m.firstFrame),
      decoded: decoded,
    ));
  }

  @override
  void event(EventMessage m) {
    if (_over) return;
    _events.add(eventOf(m));
  }

  @override
  void closed() {
    _over = true;
    _chunks.close();
    _events.close();
  }
}
