## 4.0.4

Over TajweedFormer for Android 4.0.2 and TajweedFormer for iOS and macOS 4.0.3, as 4.0.3. No change is needed in an
app.

- Android: the plugin now builds in apps on an Android Gradle Plugin older than 9.2: AGP 8, and the 9.0 and 9.1
  that Flutter 3.44 and 3.47 create apps with. With 4.0.0 to 4.0.3 such a build stopped while Gradle configured the
  plugin, with `DefaultAndroidSourceSet_Decorated cannot be cast to ... AndroidLibrarySourceSet` at line 63 of the
  plugin's `android/build.gradle.kts`. The plugin's Kotlin code is unchanged.
- Flutter 3.44 or later. With Flutter 3.41 the plugin never built on Android (that Flutter does not apply the Kotlin
  plugin to a plugin's Android project); pub now says so. Apps on 3.41 keep 4.0.3.
- Licence: the SDK and the model are now under the Quran-Lab No-Profit License 1.3 (NPL-1.3), which replaces
  NPL-1.2. NPL-1.3 forbids using the model or its outputs to train other models without Quran Lab's written
  permission, and TajweedFormer V4 and later models are used only through the SDK. The licence's Changes paragraph
  lists the rest.

## 4.0.3 (2026-11-22)

On iOS (over TajweedFormer for iOS 4.0.3; Android stays on 4.0.2), opening the model with a new `TajweedClient` or
right after `model.reference.fetch()` no longer fails with `engine_failed` (`busy`) or `reference_missing`.

## 4.0.2 (2026-11-22)

Over TajweedFormer for Android 4.0.2 and TajweedFormer for iOS and macOS 4.0.2.

- Nothing waits for Wi-Fi. The `unmeteredOnly` option of `client.prefetch()` is gone, with no replacement and no
  compatibility shim: an app that passed it removes the argument. `client.prefetch()` and every download and upload
  of the native SDKs (the model, its updates, another context's files, the accelerator's build, shared recordings)
  use whatever network the device has, mobile data included. The system may still hold a request by its own
  settings (Low Data Mode, Data Saver); the SDK adds no wait of its own. `client.diagnose().connection` still
  reports the network, for support.
- A session on another context than the one `prefetch()` installed downloads that context's files on mobile data
  too. Under the iOS SDK 4.0.1 it failed with `model_missing` at every retry until the device was on Wi-Fi.
- `TajweedError.cause` (`TajweedErrorCause`): where a failure the native SDK reports happened and why (`stage`,
  `reason`, and `httpStatus`, `errorName` and `errorCode` when there are any), the same words as the report the SDK
  sends Quran Lab, to log or to send with a support request. On `needs_connection`, `cause.needs` is `model` (the
  model files are not on the device yet: connect to download them) or `lease` (the model is on the device and needs
  Quran Lab's answer to open: connect to continue). The five codes that only say the API was used wrongly carry
  none. It also reaches a take's `TajweedEnded(error)`.

## 4.0.1

Over TajweedFormer for Android 4.0.1 and TajweedFormer for iOS and macOS 4.0.1. No change is needed in an app.

- If Quran Lab's main servers can't be reached, the SDK uses backup servers automatically. Nothing to set;
  `client.diagnose().endpoints` (`TajweedEndpoints`) says which servers it is using.
- A faster first launch: the model's files download several at a time and are checked as they arrive.
- The native SDKs send the app's version and build number with their config request, so Quran Lab can serve an
  app's older releases the model they were built with. Nothing to set: they read them from the app.
- A `client.model()` call cancelled while the model was opening no longer leaves the model open.
- The Apple SDK is now pinned to exactly 4.0.1, as the Android SDK is pinned to 4.0.1 (4.0.0 accepted any later
  4.x on iOS).
- The docs say it plainly: the first run needs a connection; after that the model works offline, and the SDK keeps
  itself up to date in the background when the device is online.

## 4.0.0

The first release on pub.dev (2026-11-19): one Flutter plugin for Android and iOS over TajweedFormer for Android 4.0
(Maven Central, `ai.quranlab:tajweedformer`) and TajweedFormer for iOS and macOS 4.0 (Swift package,
`tajweedformer-apple`), through their public API only. Its version follows the SDKs it wraps.

- The model is encrypted from Quran Lab's server to the device and runs only inside the Quran Lab Core, under a lease
  for each install. The first run needs a connection; after that the model works offline.
- The Dart API of the native SDKs: `TajweedClient`, `TajweedModel`, `TajweedSession`, `TajweedHeads`,
  `TajweedBackend`, the decoded layer and the events, and one error type `TajweedError` with the SDKs' 26 codes, one
  to one.
- Three ways to feed a take: the SDK's own microphone (`model.listen()`), the app's audio (`model.session()`, float32
  or int16), and the model's sample clips. The optional package `quranlab_tajweedformer_record` captures the
  microphone with the `record` plugin.
- `session.reportRecited(..., outcome:, perAyah:)` takes the app's own judgement (`TajweedRecitedOutcome.correct()`
  or `.incorrect(mistakes:, rules:)`), counted, never judged by the SDK.
- Sharing: every app shows the same sharing sheet, every learner is asked, and the choice is theirs: Not now, stop,
  or delete at any time. There is no `audience` option and no switch for the app. `client.sharing.ask()` is false
  where sharing is not offered.
- `client.diagnose().protectedModel`: the install's key store and the state and class of the lease the Core holds,
  for support.
- Error reports and the anonymous analytics are always on, with no option; `needsConnection` only when no request got
  an answer. Every error reaches your app's Problems page at sdk.quranlab.ai as a small anonymous report.
- Android: the SDK shows its own sharing sheet and asks for the microphone itself. Add your app's signing
  certificates on your key's page at sdk.quranlab.ai for hardware-verified installs. Every Android phone runs the
  CPU engine at launch.
- iOS: needs Flutter's Swift Package Manager integration (the Apple SDK is a Swift package only). Add the App Attest
  capability for hardware-verified installs, the Neural Engine and sharing uploads, and exclude x86_64 from
  Simulator builds (`EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`: the Core is arm64 only). The model downloads
  when the app calls `client.model()` or `client.prefetch()`. `setTheme` reaches the SDK's own consent sheet too.
- From V4.1 on, new model versions are published only encrypted, for SDK 4.0.

History: a 1.0.0 over the 3.x SDKs was built and never published; its API is the one above.
