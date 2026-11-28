// The one interface between the Dart API and a platform's SDK, with the messages of pigeon/messages.dart as its data.
// Android and iOS answer it through Pigeon's channels (the native plugins); the web through Quran Lab's hosted
// loader (src/web/); Windows and Linux through the C SDK (src/ffi/). The public classes call nothing else, so every
// platform gives the same API. Internal.
import 'dart:typed_data';

import 'messages.g.dart' as pigeon;
import 'messages.g.dart';

/// What every platform implements: the methods of `TajweedHostApi` (pigeon/messages.dart) and the stream of
/// updates. Failures are [TajweedError]s or the channel's [PlatformException]s; `guarded()` turns either into the
/// SDK's error.
abstract interface class TajweedHost {
  Future<void> createClient(String key, ClientOptionsMessage options);
  Future<void> closeClient();
  Future<ModelMessage> model(String? version, int? progressId);
  Future<void> prefetch(int? progressId);
  Future<StorageMessage> storage();
  Future<void> removeModels();
  Future<String> diagnose();
  Future<BackendMessage> modelBackend();
  Future<void> closeModel();
  Future<void> openSession(int sessionId, String mode, SessionOptionsMessage options, String? clipName,
      Uint8List? samples, int? sampleRate);
  Future<void> push(int sessionId, Uint8List pcm, bool int16);
  Future<HeadsMessage> finish(int sessionId);
  Future<void> cancel(int sessionId);
  Future<BackendMessage> sessionBackend(int sessionId);
  Future<void> reportRecited(int sessionId, int surah, int ayahFrom, int ayahTo, RecitedOutcomeMessage? outcome,
      List<RecitedOutcomeMessage> perAyah);
  Future<bool> referenceIsDownloaded();
  Future<void> referenceFetch();
  Future<UnitsMessage> referenceUnits(int surah, int ayah);
  Future<SharingStateMessage> sharingState();
  Future<void> sharingSetOn(bool on);
  Future<bool> sharingAsk();
  Future<void> sharingFeed(Uint8List pcm, bool int16, int sampleRate);
  Future<List<SharingItemMessage>> sharingItems();
  Future<SharingSummaryMessage?> sharingSummary();
  Future<bool> sharingDelete();
  Future<void> sharingSetWording(Map<String, String>? overrides);
  Future<void> sharingSetTheme(SharingThemeMessage theme);
  Future<void> sharingOpenSettings();
  Future<void> reportChecks(String rule, int checked, int flagged);

  /// Every take's chunks, events and end, and every download's progress, for the whole isolate. Listened to once.
  Stream<UpdateMessage> updates();
}

/// Android and iOS: the native plugin answers Pigeon's channels.
class PigeonHost extends TajweedHostApi implements TajweedHost {
  PigeonHost();

  @override
  Stream<UpdateMessage> updates() => pigeon.updates();
}
