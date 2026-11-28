// The one interface between the Dart API and the native SDKs behind Pigeon's channels (TajweedFormer for Android, and
// the Apple SDK for iOS). The web and the C SDK (Windows, Linux) answer the same interface in Dart
// (lib/src/host.dart), with the same messages.
//
// After editing it, regenerate the three outputs from the package folder:
//
//   dart run pigeon --input pigeon/messages.dart
//
// The Dart side (lib/src/) turns these messages into the public types. Nothing here is public API.
//
// Wire rules, the same on every platform:
// - Float samples and head values travel as little-endian float32 bytes (Uint8List): the platform channel codec
//   has no float32 list that Pigeon can name, and a float64 copy of every head would double the bytes.
// - The decoded layer travels as a delta: `tokenStart` and `frameStart` say from which index on the lists
//   replace what the Dart side holds for the take. A chunk carries only what changed since the last one, so a
//   20 minute take does not send its whole history every 320 ms.
// - Every failure of the native SDK comes back as a PlatformException whose `code` is the SDK's error code and
//   whose `details` is [fix, docs, cause]: cause is the native error's ErrorCauseMessage, or null when it has none
//  . The plugin's own errors are [fix, docs].
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: 'quranlab_tajweedformer',
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/ai/quranlab/tajweedformer/flutter/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'ai.quranlab.tajweedformer.flutter'),
    swiftOut: 'ios/quranlab_tajweedformer/Sources/quranlab_tajweedformer/Messages.g.swift',
  ),
)
class ClientOptionsMessage {
  ClientOptionsMessage();
  String? appId;
  String? appVersion;
  String? storage;
}

class BackendMessage {
  BackendMessage({required this.kind, required this.name, required this.stage});

  /// `cpu` or `accelerator`
  String kind;

  /// `cpu`, `coreml`, `coreml-compact`, or the NPU build's name
  String name;

  /// `cpu`, `downloading`, `compiling`, `testing`, `promoted`, `demoted`
  String stage;
  String? reason;
}

class TokensMessage {
  TokensMessage({required this.names, required this.blank});
  List<String> names;
  int blank;
  int? wordBar;
}

class ClipMessage {
  ClipMessage({required this.name, required this.kind, required this.durationMs});
  String name;
  String kind;
  int durationMs;
}

class CalibrationMessage {
  CalibrationMessage({required this.json, required this.sha256});

  /// calibration.json exactly as the model ships it
  String json;
  String sha256;
}

class ModelMessage {
  ModelMessage({
    required this.id,
    required this.version,
    required this.build,
    required this.contexts,
    required this.chunkMs,
    required this.defaultContext,
    required this.tokens,
    required this.hasReference,
    required this.sampleClips,
    required this.backend,
  });
  String id;
  String version;
  String build;
  List<String> contexts;

  /// the chunk length of each of [contexts], in the same order
  List<int> chunkMs;
  String defaultContext;
  TokensMessage tokens;
  CalibrationMessage? calibration;
  bool hasReference;
  List<ClipMessage> sampleClips;
  BackendMessage backend;
}

class SessionOptionsMessage {
  SessionOptionsMessage({
    required this.sampleRate,
    required this.backend,
    required this.topK,
    required this.pace,
  });
  String? context;
  int sampleRate;

  /// null: the SDK's default heads; `["all"]`: every head
  List<String>? heads;

  /// `auto`, `cpu` or `coreml-compact`
  String backend;
  int topK;
  int? endOnSilenceMs;

  /// `realTime` or `fast`
  String pace;
}

class HeadMessage {
  HeadMessage({
    required this.name,
    required this.kind,
    required this.frameMs,
    required this.frames,
    required this.classes,
    required this.values,
  });
  String name;

  /// `ctc` or `attribute`
  String kind;
  int frameMs;
  int frames;
  int classes;

  /// frames * classes float32 values, little endian, frames first
  Uint8List values;

  /// Android names the classes of an attribute head; iOS does not
  List<String>? classNames;
}

class DecodedMessage {
  DecodedMessage({
    required this.tokenStart,
    required this.tokenIds,
    required this.tokenFirstMs,
    required this.tokenPeakMs,
    required this.tokenLastMs,
    required this.tokenConfidence,
    required this.frameStart,
    required this.frameTop,
    required this.frameTopLogProb,
    required this.frameRunnerUp,
    required this.frameRunnerUpLogProb,
    required this.frameMargin,
    required this.topK,
    required this.frameTopK,
    required this.frameTopKLogProbs,
    required this.settled,
    required this.isFinal,
  });

  /// the tokens below are the take's tokens from this index on
  int tokenStart;
  Int32List tokenIds;
  Int32List tokenFirstMs;
  Int32List tokenPeakMs;
  Int32List tokenLastMs;

  /// NaN where the SDK has no confidence for a token
  Float64List tokenConfidence;

  /// the frames below are the take's 40 ms frames from this index on
  int frameStart;
  Int32List frameTop;
  Float64List frameTopLogProb;
  Int32List frameRunnerUp;
  Float64List frameRunnerUpLogProb;
  Float64List frameMargin;

  /// the K of the flat lists below (0: none)
  int topK;
  Int32List frameTopK;
  Float64List frameTopKLogProbs;
  int settled;
  bool isFinal;
}

class ChunkMessage {
  ChunkMessage({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.firstFrame,
    required this.backend,
    required this.speech,
    required this.heads,
    required this.decoded,
  });
  int index;
  int startMs;
  int endMs;
  int firstFrame;
  BackendMessage backend;
  bool speech;
  List<HeadMessage> heads;
  DecodedMessage decoded;
}

/// What failed, as the native error carries it (Android `TajweedError.errorCause`, Apple `TajweedError.cause`;
/// contract 24.13): the tokens of the SDK's report of the same failure.
class ErrorCauseMessage {
  ErrorCauseMessage({required this.stage, required this.reason});
  String stage;
  String reason;
  int? httpStatus;
  String? errorName;
  String? errorCode;

  /// needs_connection only: `model` or `lease`
  String? needs;
}

class ErrorMessage {
  ErrorMessage({required this.code, required this.message, required this.fix, required this.docs});
  String code;
  String message;
  String fix;
  String docs;
  ErrorCauseMessage? cause;
}

class EventMessage {
  EventMessage({required this.type});

  /// `speechStarted`, `speechEnded`, `interrupted`, `resumed`, `backendChanged`, `ended`
  String type;
  int? atMs;
  int? silenceMs;

  /// interrupted: `interruption` or `routeChange`
  String? cause;
  BackendMessage? backend;
  int? fromChunk;

  /// ended: `silence`, `background`, `hidden`, `interrupted`, `sourceEnd`, `limit`, `error`
  String? reason;
  ErrorMessage? error;
}

class HeadsMessage {
  HeadsMessage({required this.heads, required this.decoded});
  List<HeadMessage> heads;

  /// the final decoded layer, whole (tokenStart and frameStart are 0)
  DecodedMessage decoded;
}

class StoredModelMessage {
  StoredModelMessage({required this.version, required this.build, required this.bytes});
  String version;
  String build;
  int bytes;
}

class StorageMessage {
  StorageMessage({required this.models, required this.sharingQueueBytes});
  List<StoredModelMessage> models;
  int sharingQueueBytes;
}

class UnitsMessage {
  UnitsMessage({required this.units, required this.wordStarts});
  Int32List units;
  Int32List wordStarts;
}

class SharingStateMessage {
  SharingStateMessage({required this.available, required this.on});
  bool available;
  bool on;
  String? recoveryCode;
}

class SharingItemMessage {
  SharingItemMessage({
    required this.status,
    required this.day,
    required this.durationMs,
    required this.bytes,
  });

  /// `queued`, `uploaded` or `failed`
  String status;
  String day;
  int durationMs;
  int bytes;
}

class SharingSummaryMessage {
  SharingSummaryMessage({
    required this.mySessions,
    required this.myMinutes,
    required this.allContributors,
    required this.allMinutes,
  });
  int mySessions;
  double myMinutes;
  int? appContributors;
  double? appMinutes;
  int allContributors;
  double allMinutes;

  /// iOS gives the gratitude line in the app's language; Android leaves it to the app
  String? line;
}

/// How the app's own judge found a recited range, or one ayah of it when [ayah] is set (`reportRecited`).
class RecitedOutcomeMessage {
  RecitedOutcomeMessage({required this.correct, required this.rules});
  bool correct;

  /// 1 to 1000, or null; always null for a correct one
  int? mistakes;

  /// at most 8 rule ids; empty for a correct one
  List<String> rules;

  /// null for the whole range; the ayah of a per-ayah outcome
  int? ayah;
}

class SharingThemeMessage {
  SharingThemeMessage();

  /// ARGB colours; null keeps the sheet's own
  int? accent;
  int? background;
  int? text;
  int? secondaryText;

  /// the sheet's corner radius in logical pixels; null keeps the design's
  double? cornerRadius;

  /// null follows the system's light or dark mode (Android only)
  bool? dark;
}

/// A chunk of a take, an event of a take, the end of a take's two streams, or a download's progress.
sealed class UpdateMessage {}

class ChunkUpdate extends UpdateMessage {
  ChunkUpdate({required this.sessionId, required this.chunk});
  int sessionId;
  ChunkMessage chunk;
}

class EventUpdate extends UpdateMessage {
  EventUpdate({required this.sessionId, required this.event});
  int sessionId;
  EventMessage event;
}

class ClosedUpdate extends UpdateMessage {
  ClosedUpdate({required this.sessionId});
  int sessionId;
}

class ProgressUpdate extends UpdateMessage {
  ProgressUpdate({required this.callId, required this.done, required this.total});
  int callId;
  int done;
  int total;
}

@HostApi()
abstract class TajweedHostApi {
  /// Makes the process's one Client. The same key again (a hot restart, a second engine) gives the Client that
  /// is already there, after its takes are cancelled; another key is `client_exists`.
  @async
  void createClient(String key, ClientOptionsMessage options);

  @async
  void closeClient();

  /// Downloads (reporting to [progressId] when it is set), verifies and opens the model.
  @async
  ModelMessage model(String? version, int? progressId);

  @async
  void prefetch(int? progressId);

  @async
  StorageMessage storage();

  @async
  void removeModels();

  /// The SDK's diagnosis as JSON, the same fields on both platforms.
  @async
  String diagnose();

  @async
  BackendMessage modelBackend();

  @async
  void closeModel();

  /// [mode]: `listen` (the SDK's microphone), `clip` ([clipName]), `samples` ([samples] at [sampleRate]) or
  /// `push` (the app pushes audio). The Dart side picks [sessionId] before the call, so no update can arrive for
  /// a take it does not know yet.
  @async
  void openSession(
    int sessionId,
    String mode,
    SessionOptionsMessage options,
    String? clipName,
    Uint8List? samples,
    int? sampleRate,
  );

  /// [pcm] is float32 (little endian) or, with [int16], signed 16 bit samples (little endian).
  @async
  void push(int sessionId, Uint8List pcm, bool int16);

  @async
  HeadsMessage finish(int sessionId);

  @async
  void cancel(int sessionId);

  @async
  BackendMessage sessionBackend(int sessionId);

  /// [outcome]: the app's judgement of the whole range, or null; [perAyah]: single ayahs of the range (each with its
  /// `ayah`), which win over [outcome] for those ayahs.
  @async
  void reportRecited(int sessionId, int surah, int ayahFrom, int ayahTo, RecitedOutcomeMessage? outcome,
      List<RecitedOutcomeMessage> perAyah);

  @async
  bool referenceIsDownloaded();

  @async
  void referenceFetch();

  @async
  UnitsMessage referenceUnits(int surah, int ayah);

  @async
  SharingStateMessage sharingState();

  @async
  void sharingSetOn(bool on);

  @async
  bool sharingAsk();

  @async
  void sharingFeed(Uint8List pcm, bool int16, int sampleRate);

  @async
  List<SharingItemMessage> sharingItems();

  @async
  SharingSummaryMessage? sharingSummary();

  @async
  bool sharingDelete();

  @async
  void sharingSetWording(Map<String, String>? overrides);

  @async
  void sharingSetTheme(SharingThemeMessage theme);

  /// Shows the SDK's own sharing settings (the switch, what is shared, delete, the recovery code) over the app.
  @async
  void sharingOpenSettings();

  @async
  void reportChecks(String rule, int checked, int flagged);
}

@EventChannelApi()
abstract class TajweedEventApi {
  UpdateMessage updates();
}
