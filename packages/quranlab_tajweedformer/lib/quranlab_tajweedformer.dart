/// TajweedFormer V4 for Flutter: Quran Lab's Android and iOS SDKs 4.0 in one Dart API.
///
/// The same five things as every Quran Lab SDK: the client, the model, the session (one take), its heads and the
/// backend. Four calls, the same as every Quran Lab SDK: a client, the model, a take, its chunks.
///
/// ```dart
/// final client = await TajweedClient.create('qlk_v1_...');
/// final model = await client.model();
/// final session = await model.listen(options: const TajweedSessionOptions(endOnSilenceMs: 1500));
/// await for (final chunk in session.chunks) {
///   print(chunk.decoded.text);
/// }
/// ```
library;

export 'src/client.dart'
    show TajweedClient, TajweedClientOptions, TajweedAnalytics, TajweedStorage, TajweedStoredModel, TajweedDiagnosis,
        TajweedProtectedModel;
export 'src/errors.dart' show TajweedError, TajweedErrorCode;
export 'src/model.dart'
    show TajweedModel, TajweedTokens, TajweedClip, TajweedCalibration, TajweedReference, TajweedAyahUnits;
export 'src/output.dart';
export 'src/session.dart'
    show TajweedSession, TajweedSessionOptions, TajweedSessionBackend, TajweedPace, TajweedRecitedOutcome;
export 'src/sharing.dart' show TajweedSharing, SharingTheme, TajweedSharingItem, TajweedSharingSummary;
