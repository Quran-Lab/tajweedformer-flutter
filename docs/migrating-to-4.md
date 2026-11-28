# Moving to SDK 4.0 (Flutter)

This plugin is a thin layer over Quran Lab's Android and Apple SDKs, and it now wraps their 4.0 releases (Android
4.0.0 and Apple 4.0.0 or a later 4.x) through their public API only. This page says what changes for a Flutter app,
because the SDKs under the plugin change. The Dart names on this page are the plugin's.

What changes is underneath: in 4.0 the model is protected. It runs only inside the Quran Lab Core, a closed library in
each native SDK, and opens under a lease for this install.

**When to move.** The native SDKs 3.x stop receiving the V4 model on 15 January 2027, 00:00 UTC. New model versions,
from V4.1 on, are published only encrypted, for SDK 4.0: an app on 3.x never gets them.

| Native 3.x under the plugin | Native 4.0 under the plugin |
| --- | --- |
| The model's files on the device were plain. | They are encrypted for this install. Only the calibration and the sample clips are plain, and no call gives a model file or its path. The first start after the upgrade downloads the model once more, so it needs a connection once. |
| `client.model()` worked offline once the model was downloaded. | It still does: the first run needs a connection; after that the model works offline, and the native SDK keeps itself up to date in the background when the device is online. See "The lease". |
| The plugin has no option to turn the anonymous analytics off. | Nor do the native 4.0 SDKs: their option is removed, so the analytics are always on for every install. They are daily counts and durations only, never audio, text, names or device identifiers. Nothing to change in Dart. |
| iOS: the App Attest capability was needed only to upload shared recordings. | It also decides the install's class: with it, the install is hardware-verified and may use the Neural Engine; without it, the SDK still runs, on the CPU engine only. |
| Android: the app's signing certificates played no part. | They decide the lease on most phones: add them at sdk.quranlab.ai (below). |
| A server failure could be `TajweedErrorCode.needsConnection`. | `needsConnection` only when Quran Lab gave no answer at all. See "Error codes". |
| `session.reportRecited(surah: ..., ayahFrom: ..., ayahTo: ...)` was the only count of recited ayahs. | The SDK counts the ayahs of each take itself and uses your report only for a take it could not place; a take is never counted twice. Keep calling it if you already do. If your app judges the recitation, say so with it: `outcome: TajweedRecitedOutcome.incorrect(mistakes: 2, rules: ['madd'])` for the range, `perAyah: {3: const TajweedRecitedOutcome.correct()}` for single ayahs. The SDK counts it as your app's judgement and never judges anything itself. |

## Android

- **Add your signing certificates.** On your Android key's page at sdk.quranlab.ai, under "Signing certificates
  (SHA-256)", add the app signing key certificate and the upload key certificate (Play Console: Test and release, App
  integrity, App signing). Until you do, your installs are not hardware-verified for your app. Once Google Play
  recognizes your app, its app signing certificate counts as declared, and builds signed with your upload key
  (internal testing, sideloaded builds) are then refused unless you add the upload key certificate too.
- **Testing on cloud device labs.** Some labs re-sign your APK, so its signing digest differs from yours. Add the
  lab's signing digest to a development key, never to the production one.
- **Phones with an unlocked bootloader** are refused a lease, by design. The error says which check failed.
- **Play Integrity** needs nothing from the app. The SDK brings Google's library and asks Play only on a phone without
  usable hardware attestation. A phone with neither, or a Play outage, still gets leases: never a lock-out.
- `minSdk` stays 26. At 4.0's launch every Android phone runs the Core's CPU engine: no NPU program is served until one
  is faster than the CPU engine.
- LiteRT, the NPU runtime, is the app's own and optional: the Android SDK no longer brings it, so nothing changes in
  `android/gradle.properties`. An app that wants the NPU adds `com.google.ai.edge.litert:litert` 2.2.0 or later.
- The Android emulator runs the Core's x86_64 build, which Quran Lab leases to development keys only: use a
  development key there (a production key gets `server_rejected`).
- Nothing to host: the Android SDK 4.0 shows its own sharing sheet over the Flutter activity and asks for the
  microphone itself, also though the client is made from Dart after the activity started, and counts that opening.
  When a background job of the SDK started the app's process first, `TajweedClient.create` takes the client it made.

## iOS

- **Add the App Attest capability** (Signing & Capabilities in Xcode) for hardware-verified installs, the Neural Engine
  and uploads of shared recordings. When App Attest fails on a device, the SDK goes on unattested, on the CPU engine.
- iOS 15 or later on Apple silicon and Xcode 16, as before; the Core comes with the Apple SDK's Swift package.
- The Core is arm64 only: add `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` to `ios/Flutter/Debug.xcconfig` and
  `Release.xcconfig`, since `flutter build ios --simulator` also builds x86_64.
- `client.sharing.setTheme(...)` now also reaches the SDK's own consent sheet and re-ask card on iOS, not only the
  settings screen.
- On the Simulator, use a development key: Quran Lab leases the Core's Simulator build to development keys only.
- The Apple SDK's privacy manifests now also declare crash data (not linked to the learner, not used for tracking)
  and the boot clock, which the lease's clock reads. Check your App Store privacy answers against them.

## The lease

- **A lease per install.** The model opens under a lease Quran Lab signs for this install. The first run needs a
  connection; after that the model works offline. When the device is online the native SDK keeps itself up to date
  in the background, and opening the model never waits for that.
- **`TajweedErrorCode.needsConnection`** from `client.model()` means the SDK needs to reach Quran Lab to continue;
  an answer from a server that is a failure is `TajweedErrorCode.downloadFailed`.
- **A model already open keeps running** until it is closed.
- **Refusals.** When Quran Lab stops a key or an app, the native SDK removes the model, as in 3.x, but only when its
  Core verified the signed refusal.

## Error codes

The plugin passes the native SDK's error through unchanged, and the catalogue is the same 26 codes
(`TajweedErrorCode`). What changes is which code a failure gets: an answer from a server is never `needsConnection`.

| What happened | Code |
| --- | --- |
| A request the call needs got no answer at all (offline, DNS, a refused connection) and nothing of the model is on the device yet | `needsConnection` |
| The SDK needs to reach Quran Lab to continue, and Quran Lab gave no answer | `needsConnection` |
| Quran Lab answered with a failure: a server error, a 429, a redirect | `downloadFailed`; the message names what answered. Call again later |
| Quran Lab refused the key or the app | `invalidKey`, or `serverRejected` with the reason, as in 3.x |

The native SDKs also send Quran Lab a small report of each error your app gets and of the failures they go on from
without telling it: where it failed, why, how often that day, and the device's model code and memory tier. Never a
message, a path, a URL or an identifier. Your app's page at sdk.quranlab.ai lists them under Problems. Nothing to do in
Dart.

From 4.0.2 the error your app gets carries the same words as its report: `error.cause` (`TajweedErrorCause`: `stage`,
`reason`, `httpStatus`, `errorName`, `errorCode`). On `needsConnection`, `cause.needs` is `model` when the model files
are not on the device yet (connect to download them) and `lease` when the model is on the device and needs Quran Lab's
answer to open (connect to continue).

## Sharing

- **`audience` is removed** from `TajweedClientOptions`, with `TajweedAudience` and the `guardianConfirmed` argument
  of `client.sharing.setOn`: delete the argument. Every app shows the same sharing sheet, and every
  learner is asked, whoever the app is for. The app chooses the sheet's wording (`setWording`), its colours
  (`setTheme`) and its own moment to ask (`ask()`); a learner, or a parent through the app's own flow, can say "Not
  now", turn sharing off or delete what was shared at any time. Complying with children's privacy law (for example
  COPPA, the GDPR's rules for children, parental consent) is the developer's, through the app's own flows, its
  privacy policy and its store declarations. Quran Lab never asks or guesses a learner's age.
- **No developer switch,** as before. Every learner is asked, and the choice is theirs: "Not now", stop, or delete
  what they shared at any time. `flags.contributions` in the signed config is Quran Lab's own switch, for every app (a
  platform not offered yet, or an incident), never the app's.
- **Asked later and less often.** The first ask, the full sheet, comes never in the install's first 24 hours nor
  before its 3rd completed take. After "Not now" a small card asks again after 14 days and 7 takes, then 30 days and
  10. Three asks at most, ever. `client.sharing.ask()` resolves to false when no ask is due.
- **Takes in a row.** A shared recording stays open for up to 60 seconds after a take (3 seconds unless Quran Lab's
  config sets it), so a learner who pauses between turns gives one recording.
- **What a shared recording carries.** Its description now names the device's model code. When Quran Lab's config
  turns it on, a take captured at a rate other than 48 kHz is shared as lossless FLAC at its own rate.

## What stays the same

In the native SDKs: every call of a take, the heads and the decoded layer, events, the microphone, pushed audio, sample
clips, the sharing sheet and settings, the learner's earlier answer with the consent version they agreed to, and the 26
error codes. Quran Lab encourages, but does not
require, one line where your app shows feedback built on the model, for example: "Automatic tajweed feedback can be
wrong. It does not replace a qualified teacher."
