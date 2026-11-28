import 'dart:convert';
import 'dart:typed_data';

import 'bridge.dart';
import 'errors.dart';
import 'messages.g.dart';
import 'output.dart';
import 'session.dart';

/// One verified model build on this device, with the engine loaded. Made by `client.model()` and by nothing
/// else: a model comes from Quran Lab's server through the client. A model has one open session at a time; a
/// take is [listen] (the SDK's microphone), [listenFrom], [listenFromSamples] or [session] (you push audio).
class TajweedModel {
  TajweedModel.internal(ModelMessage m)
      : id = m.id,
        version = m.version,
        build = m.build,
        contexts = List.unmodifiable(m.contexts),
        defaultContext = m.defaultContext,
        _chunkMs = {for (var i = 0; i < m.contexts.length && i < m.chunkMs.length; i++) m.contexts[i]: m.chunkMs[i]},
        tokens = TajweedTokens._(m.tokens),
        calibration = m.calibration == null ? null : TajweedCalibration.internal(m.calibration!.json, m.calibration!.sha256),
        reference = m.hasReference ? TajweedReference._() : null,
        sampleClips = List.unmodifiable(
            m.sampleClips.map((c) => TajweedClip._(c.name, c.kind, c.durationMs)));

  /// The model's id, `v4.0`.
  final String id;

  /// The model's version, `4.0.0`.
  final String version;

  /// The build of this version on the device (40 hex digits), for diagnostics.
  final String build;

  /// The contexts the model can run (response time).
  final List<String> contexts;

  /// The context a session runs when its options name none.
  final String defaultContext;
  final Map<String, int> _chunkMs;

  /// The vocabulary: token names and ids, the blank and the word bar.
  final TajweedTokens tokens;

  /// calibration.json as shipped: read-only data for an app's own judge. The SDK never applies it.
  final TajweedCalibration? calibration;

  /// The expected units of each ayah, read-only data for an app's own judge; null when this build ships none.
  final TajweedReference? reference;

  /// Short recitations that ship with the model, to run the whole path without a microphone ([listenFrom]).
  final List<TajweedClip> sampleClips;

  Bridge get _bridge => Bridge.instance;

  /// The length of a chunk of [context] (default: [defaultContext]), in milliseconds.
  int chunkMs([String? context]) {
    final ms = _chunkMs[context ?? defaultContext];
    if (ms == null) {
      throw TajweedError(TajweedErrorCode.invalidArgument, 'context: $context is not a context of this model',
          fix: 'Use one of model.contexts: ${contexts.join(', ')}.');
    }
    return ms;
  }

  /// The backend the next session will use, and where the accelerator's promotion stands.
  Future<TajweedBackend> backend() => guarded(() async => backendOf(await _bridge.api.modelBackend()));

  /// A take fed by the SDK's own microphone: it asks for the permission (a refusal is `microphone_denied`),
  /// captures at the device's rate and carries that rate to the session. The take ends when the app leaves the
  /// foreground (`TajweedEnded(background)`; on the web when the page is hidden, `hidden`). Needs
  /// `NSMicrophoneUsageDescription` on iOS.
  /// On Windows and Linux the C SDK has no microphone: `runtime_unsupported` (capture with
  /// `quranlab_tajweedformer_record`, or push your own audio into [session]).
  Future<TajweedSession> listen({TajweedSessionOptions options = const TajweedSessionOptions()}) =>
      _open('listen', options, pushes: false);

  /// The same path with no microphone: a session fed by one of [sampleClips]. It ends with
  /// `TajweedEnded(sourceEnd)`. On Windows and Linux the C SDK runs the clip to its end at the clip's pace:
  /// `cancel()` and the model's other calls wait until the clip has ended.
  Future<TajweedSession> listenFrom(TajweedClip clip, {TajweedSessionOptions options = const TajweedSessionOptions()}) =>
      _open('clip', options, pushes: false, clipName: clip.name);

  /// The same with samples the app already has: mono float in -1..1 at [sampleRate].
  Future<TajweedSession> listenFromSamples(Float32List samples, int sampleRate,
          {TajweedSessionOptions options = const TajweedSessionOptions()}) =>
      _open('samples', options, pushes: false, samples: bytesOfFloats(samples), sampleRate: sampleRate);

  /// A take the app feeds with `session.push(...)`, at `options.sampleRate` (16000 by default).
  Future<TajweedSession> session({TajweedSessionOptions options = const TajweedSessionOptions()}) =>
      _open('push', options, pushes: true);

  Future<TajweedSession> _open(String mode, TajweedSessionOptions options,
      {required bool pushes, String? clipName, Uint8List? samples, int? sampleRate}) async {
    final id = _bridge.nextId();
    final s = TajweedSession.internal(id, tokens.names, tokens.blank, tokens.wordBar, pushes: pushes);
    _bridge.register(id, s);
    try {
      await guarded(() => _bridge.api.openSession(id, mode, options.toMessage(), clipName, samples, sampleRate));
    } catch (_) {
      _bridge.unregister(id);
      rethrow;
    }
    return s;
  }

  /// Releases the engine. An open session is cancelled.
  Future<void> close() => guarded(() => _bridge.api.closeModel());
}

/// The model's vocabulary (tokens.txt).
class TajweedTokens {
  TajweedTokens._(TokensMessage m)
      : names = List.unmodifiable(m.names),
        blank = m.blank,
        wordBar = m.wordBar;

  /// Every token's name, by id.
  final List<String> names;

  /// The id of the CTC blank (0).
  final int blank;

  /// The id of the word bar `|`, or null when the vocabulary has none.
  final int? wordBar;

  int get count => names.length;

  /// The name of a token id; `?` outside the vocabulary.
  String name(int id) => id >= 0 && id < names.length ? names[id] : '?';

  /// The id of a token name, or null.
  int? id(String name) {
    final i = names.indexOf(name);
    return i < 0 ? null : i;
  }
}

/// A short recitation that ships with the model, for running without a microphone.
class TajweedClip {
  const TajweedClip._(this.name, this.kind, this.durationMs);
  final String name;

  /// `clean`, or `planted` for a clip with a deliberate mistake in it.
  final String kind;
  final int durationMs;

  @override
  String toString() => 'TajweedClip($name, $kind, $durationMs ms)';
}

/// calibration.json exactly as the model ships it (format `quranlab.tajweed-calibration/1`): the thresholds and
/// weights Quran Lab measured for this model, for an app's own judge. The SDK reads none of it.
class TajweedCalibration {
  TajweedCalibration.internal(this.json, String sha256)
      : sha256 = sha256.toLowerCase(),
        _root = _parse(json);

  /// The file's text as shipped.
  final String json;

  /// The file's SHA-256 from the signed manifest (lower-case hex).
  final String sha256;
  final Map<String, Object?> _root;

  static Map<String, Object?> _parse(String json) {
    try {
      final v = jsonDecode(json);
      return v is Map<String, Object?> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  String get format => _root['format'] as String? ?? '';
  String? get modelId => _root['model_id'] as String?;
  String? get tokensSha256 => _root['tokens_sha256'] as String?;
  String? get defaultContext => _root['default_context'] as String?;
  String? get defaultPreset => _root['default_preset'] as String?;
  List<String> get classes => [...?(_root['classes'] as List?)?.whereType<String>()];
  List<String> get presets => [...?(_root['presets'] as Map?)?.keys.whereType<String>()];
  List<String> get contexts => [...?(_root['contexts'] as Map?)?.keys.whereType<String>()];

  /// The threshold in nats of a site class at a preset: `contexts.<context>.sites.<class>.thresholds.<preset>`.
  double? threshold(String context, String siteClass, String preset) =>
      _number(value(['contexts', context, 'sites', siteClass, 'thresholds', preset]));

  /// `validated`, `experimental` or `off`.
  String? status(String context, String siteClass) =>
      value(['contexts', context, 'sites', siteClass, 'status']) as String?;

  /// The fusion weight `a` of a class: its own, else the context's default.
  double? fusionWeight(String context, String siteClass) => _number(
      value(['contexts', context, 'fusion', 'a', siteClass]) ?? value(['contexts', context, 'fusion', 'a', 'default']));

  /// Any value of the file by its path of keys, for the fields without an accessor.
  Object? value(List<String> path) {
    Object? v = _root;
    for (final k in path) {
      if (v is! Map) return null;
      v = v[k];
      if (v == null) return null;
    }
    return v;
  }

  static double? _number(Object? v) => v is num ? v.toDouble() : null;
}

/// The expected units of each ayah, as data: a lookup by surah and ayah. The SDK never aligns them with a take.
class TajweedReference {
  TajweedReference._();

  Bridge get _bridge => Bridge.instance;

  /// Whether the table is on this device.
  Future<bool> isDownloaded() => guarded(() => _bridge.api.referenceIsDownloaded());

  /// Downloads and verifies the table, once. Later calls return at once.
  Future<void> fetch() => guarded(() => _bridge.api.referenceFetch());

  /// The unit ids of an ayah and the index of the first unit of each word. `reference_missing` before [fetch];
  /// `invalid_argument` for a surah or ayah that does not exist.
  Future<TajweedAyahUnits> units(int surah, int ayah) => guarded(() async {
        final m = await _bridge.api.referenceUnits(surah, ayah);
        return TajweedAyahUnits(List.unmodifiable(m.units), List.unmodifiable(m.wordStarts));
      });
}

/// One ayah's expected units ([units], with the word bar between words as the table has it) and where each word
/// starts in them ([wordStarts]).
class TajweedAyahUnits {
  const TajweedAyahUnits(this.units, this.wordStarts);
  final List<int> units;
  final List<int> wordStarts;
}
