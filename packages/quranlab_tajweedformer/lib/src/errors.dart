import 'package:flutter/services.dart';

/// Every failure of the SDK: one type, with a stable [code] (the same string in the Android, Apple, web and C
/// SDKs), a [message], a [fix] (one sentence a developer can act on) and a [docs] link.
///
/// Compare [code], never [message]. The codes are listed in [TajweedErrorCode].
///
/// ```dart
/// try {
///   await client.model();
/// } on TajweedError catch (e) {
///   if (e.code == TajweedErrorCode.needsConnection) showOfflineHint();
/// }
/// ```
class TajweedError implements Exception {
  const TajweedError(this.code, this.message, {this.fix = '', String? docs})
      : docs = docs ?? 'https://sdk.quranlab.ai/docs/errors#$code';

  /// The stable code of the failure, for example `needs_connection`.
  final String code;

  /// What happened, in one sentence.
  final String message;

  /// What to do about it, in one sentence.
  final String fix;

  /// The documentation of this code: `https://sdk.quranlab.ai/docs/errors#<code>`.
  final String docs;

  /// A failure the native SDK reported through the platform channel, as the SDK's own error. A channel with no
  /// native side (a platform this package does not run on) is `runtime_unsupported`.
  static TajweedError from(Object error) {
    if (error is TajweedError) return error;
    if (error is PlatformException) {
      final details = error.details;
      var fix = '';
      String? docs;
      if (details is List && details.length >= 2) {
        fix = details[0] is String ? details[0] as String : '';
        docs = details[1] is String ? details[1] as String : null;
      }
      if (error.code == 'channel-error') {
        return const TajweedError(TajweedErrorCode.runtimeUnsupported,
            'The TajweedFormer plugin has no native side on this platform.',
            fix: 'Run the app on Android or iOS; rebuild it after adding the package (a hot restart does not load a '
                'new plugin).');
      }
      return TajweedError(error.code, error.message ?? error.code, fix: fix, docs: docs);
    }
    if (error is MissingPluginException) {
      return const TajweedError(TajweedErrorCode.runtimeUnsupported,
          'The TajweedFormer plugin has no native side on this platform.',
          fix: 'Run the app on Android or iOS; rebuild it after adding the package (a hot restart does not load a new '
              'plugin).');
    }
    return TajweedError(TajweedErrorCode.engineFailed, error.toString());
  }

  @override
  String toString() => 'TajweedError($code): $message';

  @override
  bool operator ==(Object other) =>
      other is TajweedError && other.code == code && other.message == message && other.fix == fix && other.docs == docs;

  @override
  int get hashCode => Object.hash(code, message, fix, docs);
}

/// The 26 codes of the error catalogue every Quran Lab SDK shares (https://sdk.quranlab.ai/docs/errors). SDK 4.0
/// keeps the same 26, so a `switch` over them stays exhaustive; what 4.0 changes is which code a failure gets:
///
/// - [needsConnection] only when a request the call cannot go without got no answer at all: the model is not on the
///   device yet, or, in 4.0, the install's lease has ended (with its 24 hours of grace when Quran Lab cannot be
///   reached) and Quran Lab gave no answer.
/// - [downloadFailed] for every answer of a server that is a failure: a 5xx, a 429, a redirect, a lease service that
///   is briefly unavailable. Call again later; a download resumes where it stopped.
/// - [invalidKey], [serverRejected] (with the reason) or [sdkTooOld] when Quran Lab refused the key or the app.
/// - [checksumMismatch] for a downloaded file that does not match the signed manifest.
///
/// A model that opens in the lease's grace is no failure: the call goes on and the native SDK reports it to Quran
/// Lab. The native SDK also reports every error the app gets (except the five that only say the API was used wrongly:
/// [invalidArgument], [clientExists], [sessionOpen], [sessionClosed], [cancelled]), and the failures it goes on from
/// without telling the app: where it failed and why, never a message, a path or an identifier. They are listed under
/// Problems on the app's page at sdk.quranlab.ai. There is nothing to call for that, and no option turns it off.
abstract final class TajweedErrorCode {
  static const invalidArgument = 'invalid_argument';
  static const invalidKey = 'invalid_key';
  static const sdkTooOld = 'sdk_too_old';
  static const serverRejected = 'server_rejected';
  static const clientExists = 'client_exists';
  static const modelUnavailable = 'model_unavailable';
  static const needsConnection = 'needs_connection';
  static const networkNotPermitted = 'network_not_permitted';
  static const downloadFailed = 'download_failed';
  static const storageFull = 'storage_full';
  static const storageFailed = 'storage_failed';
  static const modelMissing = 'model_missing';
  static const modelInvalid = 'model_invalid';
  static const signatureInvalid = 'signature_invalid';
  static const checksumMismatch = 'checksum_mismatch';
  static const modelIncompatible = 'model_incompatible';
  static const referenceMissing = 'reference_missing';
  static const sessionOpen = 'session_open';
  static const sessionClosed = 'session_closed';
  static const cancelled = 'cancelled';
  static const engineFailed = 'engine_failed';
  static const runtimeUnsupported = 'runtime_unsupported';
  static const microphoneDenied = 'microphone_denied';
  static const microphoneUnavailable = 'microphone_unavailable';
  static const interrupted = 'interrupted';
  static const sharingUnavailable = 'sharing_unavailable';

  /// Every code, in the catalogue's order.
  static const all = <String>[
    invalidArgument, invalidKey, sdkTooOld, serverRejected, clientExists, modelUnavailable, needsConnection,
    networkNotPermitted, downloadFailed, storageFull, storageFailed, modelMissing, modelInvalid, signatureInvalid,
    checksumMismatch, modelIncompatible, runtimeUnsupported, referenceMissing, sessionOpen, sessionClosed, cancelled,
    engineFailed, microphoneDenied, microphoneUnavailable, interrupted, sharingUnavailable,
  ];
}

/// The catalogue's `invalid_argument` for an argument the Dart side checks before any call (the native SDKs word it
/// the same way).
TajweedError invalidArgument(String detail) => TajweedError(TajweedErrorCode.invalidArgument, 'Invalid argument: $detail.',
    fix: 'Pass a value the API accepts: a context or head name the model lists, a sample rate the SDK can resample, a '
        'surah from 1 to 114 with ayahs inside it, a rule name of lower-case letters, digits and underscores.');

/// Runs a platform call and turns its failure into a [TajweedError].
Future<T> guarded<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    throw TajweedError.from(e);
  }
}
