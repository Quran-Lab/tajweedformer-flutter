import 'dart:typed_data';

import 'bridge.dart';
import 'errors.dart';
import 'host.dart';
import 'messages.g.dart';

/// Recitation sharing, reached through `client.sharing`.
///
/// Every learner is asked, and the choice is theirs: there is nothing for the app to switch on or off, and no option
/// for it. The native SDK asks the learner with Quran Lab's own sheet at a quiet moment: never in the install's first
/// 24 hours nor before its third finished take, after a take, then after "Not now" a small card 14 days and 7 takes
/// later (30 days and 10 after the second), three asks at most per install, and a yes is never asked again. The
/// learner can say "Not now", stop, or delete what they shared at any time. While the learner said yes every take is
/// shared, in the background; takes in a row (up to 60 seconds apart, as Quran Lab's config sets it) make one
/// recording. Quran Lab's own switch in its signed config (`flags.contributions`, for every app: a platform not
/// offered yet, or an incident) can pause sharing; [isAvailable] is false then.
///
/// The sheet is the SDK's own, shown by the native SDK itself over the Flutter activity (Android) or the front view
/// controller (iOS). What an app may do here: nothing (the default), give the learner a settings entry
/// ([openSettings]), pick its own moment to ask ([ask]), word the sheet itself ([setWording]), give it its colours
/// ([setTheme]), and feed the audio it captures outside takes ([feed]). [setOn] is the learner's own switch, for an
/// app that draws its own settings row.
class TajweedSharing {
  TajweedSharing.internal();

  TajweedHost get _api => Bridge.instance.api;

  /// Sharing is offered on this device: false only while Quran Lab's own switch has it off. Offered is not consent.
  Future<bool> isAvailable() => guarded(() async => (await _api.sharingState()).available);

  /// The learner said yes and has not turned it off.
  Future<bool> isOn() => guarded(() async => (await _api.sharingState()).on);

  /// The learner's settings switch. Off ends the upload in progress and deletes the queue of recordings not sent
  /// yet. On, while Quran Lab's switch has sharing off, is `sharing_unavailable`.
  Future<void> setOn(bool on) => guarded(() => _api.sharingSetOn(on));

  /// Asks now, at the app's own moment, when an ask is due by the SDK's own rules: after a finished take of this app
  /// session with no take running, never at launch, never twice in a day, at most three per install, never after a
  /// yes or after the switch was turned off. Returns whether an ask is on screen now (the sheet, or for a re-ask the
  /// card); false, with nothing shown, when none is due or Quran Lab's switch has sharing off. An ask counts only
  /// once it is on screen.
  Future<bool> ask() => guarded(() => _api.sharingAsk());

  /// Audio the app captures OUTSIDE takes (before the first, between them, after the last), mono float in -1..1,
  /// so a shared recording is not cut at a take's edges. Kept in memory only (the last second), and only while the
  /// learner said yes; the model never sees it. An app that uses `model.listen()` does not need it.
  Future<void> feed(Float32List samples, int sampleRate) =>
      guarded(() => _api.sharingFeed(bytesOfFloats(samples), false, sampleRate));

  /// The same as [feed] for signed 16-bit samples.
  Future<void> feedInt16(Int16List samples, int sampleRate) =>
      guarded(() => _api.sharingFeed(bytesOfInt16(samples), true, sampleRate));

  /// The outbox: one entry per recording, oldest first.
  Future<List<TajweedSharingItem>> items() => guarded(() async => [
        for (final i in await _api.sharingItems()) TajweedSharingItem._(i.status, i.day, i.durationMs, i.bytes),
      ]);

  /// The learner's summary from Quran Lab (their shared minutes, the app's and everyone's); null when nothing
  /// was shared or the call fails.
  Future<TajweedSharingSummary?> summary() => guarded(() async {
        final s = await _api.sharingSummary();
        return s == null ? null : TajweedSharingSummary._(s);
      });

  /// "Delete what I shared": everything this learner shared from this app is deleted from Quran Lab's servers,
  /// the queue is emptied and sharing goes off. True when the server accepted it (or nothing had been shared),
  /// false when there was no connection or the server refused (nothing changed; try again). `storage_failed` when
  /// the device cannot read the learner's contributor id, device key or recovery code.
  Future<bool> delete() => guarded(() => _api.sharingDelete());

  /// The learner's recovery code, for deleting what they shared when the device is lost; null before anything
  /// was shared. Show it only to the learner, on request (the settings screen does).
  Future<String?> recoveryCode() => guarded(() async => (await _api.sharingState()).recoveryCode);

  /// The app's own wording for the sheet, by the copy deck's keys (null or empty: Quran Lab's wording again). An
  /// unknown key or an empty text is `invalid_argument`. Your words must still say what is sent, to whom, why, and
  /// how to stop and delete. A learner who already said yes is never asked again.
  Future<void> setWording(Map<String, String>? overrides) => guarded(() => _api.sharingSetWording(overrides));

  /// The sheet's and the settings screen's colours and corner radius. A theme never changes the sheet's order, a
  /// line, the name at its top or the consent version. Both platforms apply it to the SDK's own consent sheet, its
  /// re-ask card and the settings screen.
  Future<void> setTheme(SharingTheme theme) => guarded(() => _api.sharingSetTheme(theme._message()));

  /// Shows the SDK's own sharing settings over the app: the switch, "What is shared", "Delete what I shared"
  /// (with its confirmation) and the recovery code. Put it behind a row of your settings screen. It works whatever
  /// Quran Lab's config says, so a learner can always stop and delete.
  Future<void> openSettings() => guarded(() => _api.sharingOpenSettings());
}

/// The colours and corner radius of the SDK's sharing sheet and settings. Null keeps the design's own value.
class SharingTheme {
  const SharingTheme({this.accent, this.background, this.text, this.secondaryText, this.cornerRadius, this.dark});

  /// ARGB colours (`Color.toARGB32()`).
  final int? accent;
  final int? background;
  final int? text;
  final int? secondaryText;

  /// The sheet's corner radius in logical pixels (the design's is 28).
  final double? cornerRadius;

  /// Android: light or dark fixed; null follows the system.
  final bool? dark;

  SharingThemeMessage _message() => SharingThemeMessage(
        accent: accent,
        background: background,
        text: text,
        secondaryText: secondaryText,
        cornerRadius: cornerRadius,
        dark: dark,
      );
}

/// One recording in the outbox.
class TajweedSharingItem {
  const TajweedSharingItem._(this.status, this.day, this.durationMs, this.bytes);

  /// `queued` (recording, waiting or uploading), `uploaded` or `failed`.
  final String status;

  /// Its UTC day.
  final String day;
  final int durationMs;
  final int bytes;
}

/// The learner's own shared minutes, this app's and Quran Lab's totals.
class TajweedSharingSummary {
  TajweedSharingSummary._(SharingSummaryMessage m)
      : mySessions = m.mySessions,
        myMinutes = m.myMinutes,
        appContributors = m.appContributors,
        appMinutes = m.appMinutes,
        allContributors = m.allContributors,
        allMinutes = m.allMinutes,
        line = m.line;

  final int mySessions;
  final double myMinutes;

  /// Null while the app has fewer than ten contributors.
  final int? appContributors;
  final double? appMinutes;
  final int allContributors;
  final double allMinutes;

  /// iOS: the gratitude line of the copy deck with the learner's minutes, in the app's language. Null on Android.
  final String? line;
}
