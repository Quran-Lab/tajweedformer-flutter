import 'dart:convert';

import 'bridge.dart';
import 'errors.dart';
import 'messages.g.dart';
import 'model.dart';
import 'output.dart';
import 'sharing.dart';

/// What a client may be told besides its key. Every field has a default.
///
/// There is no option for the anonymous analytics: in SDK 4.0 they are always on (daily counts and durations only,
/// never audio, text, names or device identifiers), and only Quran Lab can switch them off, from its signed config.
/// Nor is there one for sharing: every learner is asked by the SDK, and the choice is theirs.
class TajweedClientOptions {
  const TajweedClientOptions({this.appId, this.appVersion, this.storage});

  /// The app's id as registered at sdk.quranlab.ai. Null: the app's own (the package name on Android, the bundle
  /// id on iOS).
  final String? appId;

  /// The app's version. Null: the app's own.
  final String? appVersion;

  /// An absolute folder where the SDK keeps its files (the model, the signed config, the sharing queue). Null: the
  /// platform's private folder. The folder is the SDK's to fill: a model it did not download itself is deleted.
  final String? storage;
}

/// The app's link to Quran Lab: the key, the signed config, registration, the install's lease, anonymous usage
/// statistics, issue and error reports, recitation sharing, and the model files on disk. One per process: make it once with [create] and
/// keep it.
///
/// ```dart
/// final client = await TajweedClient.create('qlk_v1_...'); // your key from sdk.quranlab.ai
/// final model = await client.model();                        // downloads once, verifies, opens the engine
/// ```
class TajweedClient {
  TajweedClient._(this.key, this.options);

  static TajweedClient? _current;
  static Future<TajweedClient>? _creating;

  /// The key the client was made with.
  final String key;
  final TajweedClientOptions options;
  bool _closed = false;

  /// Recitation sharing: the SDK asks the learner, and shares only after the learner's yes.
  late final TajweedSharing sharing = TajweedSharing.internal();

  /// The app's own counters for its statistics at sdk.quranlab.ai.
  late final TajweedAnalytics analytics = TajweedAnalytics._();

  Bridge get _bridge => Bridge.instance;

  /// The client of this process, once [create] has made it.
  static TajweedClient? get current => _current;

  /// Makes the process's one client with the app's key from sdk.quranlab.ai (`qlk_v1_...`, an apps key for this
  /// app's package name and bundle id). The same key again gives the same client; another key while one is open
  /// is `client_exists`; a string that is not a Quran Lab key is `invalid_argument`.
  static Future<TajweedClient> create(String key, {TajweedClientOptions options = const TajweedClientOptions()}) {
    final cur = _current;
    if (cur != null) {
      if (cur.key == key) return Future.value(cur);
      return Future.error(const TajweedError(TajweedErrorCode.clientExists, 'A TajweedClient is already open in this process.',
          fix: 'Keep the one client and reuse it; close it before making one with another key.'));
    }
    return _creating ??= () async {
      try {
        await guarded(() => Bridge.instance.api.createClient(
            key,
            ClientOptionsMessage(
              appId: options.appId,
              appVersion: options.appVersion,
              storage: options.storage,
            )));
        return _current = TajweedClient._(key, options);
      } finally {
        _creating = null;
      }
    }();
  }

  void _checkOpen() {
    if (_closed) {
      throw const TajweedError(TajweedErrorCode.invalidArgument, 'client: it is closed',
          fix: 'Make a new client with TajweedClient.create.');
    }
  }

  /// The model for this app. The first call downloads it (the CPU files of the context in use, about 56 MB),
  /// verifies every file, opens the engine and warms it; later calls return the model that is already open.
  /// Call it early (at app start) so the first take starts at once.
  ///
  /// SDK 4.0: the model is encrypted for this install and opens only inside the native SDK's Core, under a lease
  /// Quran Lab signs for the install (learners keep working offline for days at a time; the exact time is set by
  /// Quran Lab and may change), renewed in the background whenever the device is online. Offline with a valid lease, the model opens. When the lease has ended and Quran
  /// Lab cannot be reached (no answer, a server error, too many requests), the model still opens for up to 24 hours
  /// more, and the native SDK reports it; a refusal ends that at once. A model already open keeps running.
  ///
  /// [version] pins a model version (`4.0.0`); null takes the version Quran Lab serves this app. [onProgress]
  /// gets the bytes done and the total while the version Quran Lab serves is downloaded (a pinned [version]
  /// downloads without progress). Errors: `needs_connection` (no answer, and nothing on the device or no lease
  /// left), `download_failed` (Quran Lab or the CDN answered with a failure: call again later), `storage_full`,
  /// `storage_failed`, `invalid_key`, `sdk_too_old`, `server_rejected` (a refused key or app, a production key on an
  /// emulator or simulator), `model_unavailable` and the model's own.
  Future<TajweedModel> model({String? version, void Function(int done, int total)? onProgress}) async {
    _checkOpen();
    final p = _bridge.progress(onProgress);
    try {
      return TajweedModel.internal(await guarded(() => _bridge.api.model(version, p)));
    } finally {
      _bridge.done(p);
    }
  }

  /// Downloads and verifies the model ahead of use, without opening it. Resumable; a no-op when everything is on
  /// the device. With [unmeteredOnly] nothing is downloaded on a metered connection or none (call it again
  /// later). Safe to call at every app start.
  Future<void> prefetch({bool unmeteredOnly = false, void Function(int done, int total)? onProgress}) async {
    _checkOpen();
    final p = _bridge.progress(onProgress);
    try {
      await guarded(() => _bridge.api.prefetch(unmeteredOnly, p));
    } finally {
      _bridge.done(p);
    }
  }

  /// What the SDK holds on disk.
  Future<TajweedStorage> storage() => guarded(() async {
        final m = await _bridge.api.storage();
        return TajweedStorage._(
            [for (final s in m.models) TajweedStoredModel._(s.version, s.build, s.bytes)], m.sharingQueueBytes);
      });

  /// Removes every model file from the device (the next `model()` downloads again). The learner's sharing choice
  /// and the upload queue stay.
  Future<void> removeModels() => guarded(() => _bridge.api.removeModels());

  /// Where the SDK stands, in one report that is safe to paste into an issue: no audio, no text, no identifier.
  Future<TajweedDiagnosis> diagnose() => guarded(() async => TajweedDiagnosis.fromJson(await _bridge.api.diagnose()));

  /// Ends the client: the open model and its session are closed. Another client can be made after it.
  Future<void> close() async {
    if (_closed) return;
    await guarded(() => _bridge.api.closeClient());
    _closed = true;
    if (identical(_current, this)) _current = null;
  }
}

/// The app's own counters about its own judge, for its statistics at sdk.quranlab.ai: nothing of these is sent
/// unless the app calls them. The SDK's anonymous analytics are always on, beside them.
class TajweedAnalytics {
  TajweedAnalytics._();

  /// How many times the app's own judge checked a rule and how many of those it flagged. [rule] is lower-case
  /// letters, digits and underscores (the calibration's class ids where they apply), 0 <= flagged <= checked.
  Future<void> reportChecks(String rule, {required int checked, required int flagged}) =>
      guarded(() => Bridge.instance.api.reportChecks(rule, checked, flagged));
}

/// One model build on disk.
class TajweedStoredModel {
  const TajweedStoredModel._(this.version, this.build, this.bytes);
  final String version;
  final String build;
  final int bytes;
}

/// What the SDK holds on disk.
class TajweedStorage {
  const TajweedStorage._(this.models, this.sharingQueueBytes);

  /// One entry per model build, ordered by version then build.
  final List<TajweedStoredModel> models;

  /// The bytes of the recordings waiting to be sent.
  final int sharingQueueBytes;
}

/// The protected model in `diagnose()` (SDK 4.0, the same object on Android, Apple, C and web): where the install's key
/// lives and the lease the Core holds. A lease shows here and in whether the model opens: there is nothing to set.
class TajweedProtectedModel {
  TajweedProtectedModel._(Map<String, Object?> m)
      : keyStore = m['keyStore'] as String?,
        lease = m['lease'] as String? ?? 'none',
        leaseExpires = (m['leaseExpires'] as num?)?.toInt(),
        leaseClass = m['leaseClass'] as String?,
        refreshAfter = (m['refreshAfter'] as num?)?.toInt(),
        graceUntil = (m['graceUntil'] as num?)?.toInt(),
        core = m['core'] as String?;

  /// Where the install's agreement key lives: Android `strongbox`, `tee` or `software`; iOS `secureEnclave`,
  /// `keychain`, `software` or `file`. Null before the install asked for its first lease.
  final String? keyStore;

  /// `valid`, `grace` (expired, and the model opens in its 24 hours because Quran Lab could not be reached),
  /// `expired`, `stopped` (a refusal the Core verified) or `none`.
  final String lease;

  /// The lease's end, unix seconds (also once it has expired or was stopped); null without a lease.
  final int? leaseExpires;

  /// `attested` (a hardware-verified install of a production key, the class that may use the accelerator) or
  /// `standard`; null without a lease, or when the SDK does not say.
  final String? leaseClass;

  /// When the native SDK renews the lease in the background, unix seconds; null when unknown.
  final int? refreshAfter;

  /// The end of the grace, unix seconds, only while [lease] is `grace`.
  final int? graceUntil;

  /// The Core's release and target (`4.0.0-c3 android-arm64-v8a`); null while it is not loaded.
  final String? core;
}

/// `client.diagnose()`: where the SDK stands, with the same fields on every Quran Lab SDK.
class TajweedDiagnosis {
  TajweedDiagnosis._(this.json, Map<String, Object?> m)
      : sdkVersion = (m['sdk'] as Map?)?['version'] as String? ?? '',
        sdkLatest = (m['sdk'] as Map?)?['latest'] as String?,
        keyAccepted = (m['key'] as Map?)?['accepted'] as bool?,
        keyReason = (m['key'] as Map?)?['reason'] as String?,
        config = m['config'] as String? ?? 'none',
        modelVersion = (m['model'] as Map?)?['version'] as String?,
        modelBuild = (m['model'] as Map?)?['build'] as String?,
        modelVerified = (m['model'] as Map?)?['verified'] as bool? ?? false,
        context = m['context'] as String?,
        backend = _backend(m['backend']),
        microphone = m['microphone'] as String? ?? 'notAsked',
        lastError = m['lastError'] as String?,
        droppedChunks = (m['droppedChunks'] as num?)?.toInt() ?? 0,
        connection = m['connection'] as String? ?? 'unknown',
        downloadProtocol = m['downloadProtocol'] as String?,
        protectedModel = m['protected'] is Map ? TajweedProtectedModel._((m['protected'] as Map).cast<String, Object?>()) : null;

  factory TajweedDiagnosis.fromJson(String json) {
    final v = jsonDecode(json);
    return TajweedDiagnosis._(json, v is Map<String, Object?> ? v : const {});
  }

  /// The report exactly as the native SDK wrote it, for pasting into an issue.
  final String json;

  /// The native SDK's version (Android or iOS), and the newest one Quran Lab's config names.
  final String sdkVersion;
  final String? sdkLatest;

  /// True, false, or null while no answer from Quran Lab was seen; when false, [keyReason] says why.
  final bool? keyAccepted;
  final String? keyReason;

  /// The signed config: `fresh`, `stale` or `none`.
  final String config;
  final String? modelVersion;
  final String? modelBuild;
  final bool modelVerified;
  final String? context;
  final TajweedBackend? backend;

  /// The microphone permission: `granted`, `denied` or `notAsked`.
  final String microphone;

  /// The catalogue code of the last error the SDK raised in this process.
  final String? lastError;
  final int droppedChunks;

  /// `unmetered`, `metered`, `none` or `unknown`.
  final String connection;

  /// Android only: the protocol of the last model request (`http/1.1`), or null.
  final String? downloadProtocol;

  /// SDK 4.0: the protected model, its key store and the install's lease as the Core holds it; null where the native
  /// SDK writes none (a client without a key).
  final TajweedProtectedModel? protectedModel;

  static TajweedBackend? _backend(Object? b) {
    if (b is! Map) return null;
    return backendOf(BackendMessage(
        kind: b['kind'] as String? ?? 'cpu',
        name: b['name'] as String? ?? 'cpu',
        stage: b['stage'] as String? ?? 'cpu',
        reason: b['reason'] as String?));
  }

  @override
  String toString() => json;
}
