## 4.1.0 (2026-11-28)

Windows, Linux and the web, with the same Dart API as on Android and iOS: the same calls, the same messages, the same
catalogue of errors. What a platform cannot do answers with that catalogue's error, never a silent difference. iOS
moves to TajweedFormer for iOS 4.0.5 and Android to TajweedFormer for Android 4.0.5. A new platform is a new minor
version of the plugin, so 4.1.0 runs over SDKs 4.0.x.

- **Windows** (x64) and **Linux** (x86-64) over TajweedFormer for Windows and Linux (the C SDK) 4.0.3, through
  `dart:ffi`, with bindings generated from its public header. Windows bundles the C SDK's release
  (`tajweedformer.dll`, `qlcore.dll`, `libwinpthread-1.dll`, checked by SHA-256) beside the program. Linux builds
  `libtajweedformer.so` from the C SDK's public source at its release tag over the Core's published `qlcore.so` (the
  build machine needs git and the libcurl and OpenSSL 3 development files). Takes, downloads and every call that
  waits for the network run on the plugin's own isolates, never on the UI's. Use a desktop key; a Windows app without
  a package identity passes `TajweedClientOptions(appId: ...)`, and on Linux the app id is the runner's GTK
  application id. The model runs on the Core's CPU engine: no Neural Engine, NPU or hardware-verified install there.
  - `model.listen()` is `runtime_unsupported`: the C SDK has no microphone. `quranlab_tajweedformer_record` is the
    microphone there, or push your own audio into `model.session()`.
  - The sharing sheet, its re-ask card and its settings are drawn by the plugin in the app's `Overlay`, from the C
    SDK's copy deck, in the design every SDK shares; the C SDK's rules decide when an ask comes, and a learner who
    said yes is never asked again.
  - `listenFrom(clip)` runs the clip to its end at the clip's pace (`cancel()` and the model's other calls wait until
    it has ended); `sharing.items()` carries no duration or size; `diagnose().microphone` is `none`.
- **The web** over Quran Lab's hosted loader, the same one the npm package `@quran-lab/tajweedformer` loads: the
  model, its lease and its storage live in Quran Lab's frame, exactly as with the web SDK, and the model runs on its
  CPU engine in WebAssembly. Use a web key that lists your site's origins, and add the web SDK's
  Content-Security-Policy lines when your site sends one. `TajweedClientOptions.storage` is the web SDK's storage
  name; a take from `model.listen()` ends with `hidden` when the page is hidden; `client.sharing.ask()` resolves once
  the learner has answered.
- **iOS** over TajweedFormer for iOS 4.0.5 (exactly that version):
  - `model.sampleClips` are the model build's own clips, also without the Neural Engine's build.
  - A moment without a network, or App Attest not answering, no longer leaves an install unattested for hours, and
    a model refused with `lease_attestation_required` is asked for again once the install is attested.
  - An answer from Quran Lab that fails the SDK's checks is `download_failed`, never `needs_connection`, with the
    check in `error.cause.errorCode` (`cause.reason` `invalid_answer`). `client.diagnose()` adds the install's
    attestation and the last failure of the model's access.
  - `model.reference.units()` no longer waits while the Neural Engine's build is prepared; called on the main
    thread in 4.0.3, it could freeze the app.
  - Locking the iPhone or switching apps while the Neural Engine's build is prepared is no longer counted as a
    failure of the build.
  - A shared recording made at 8 to 24 kHz keeps its last moments.
- **Android** over TajweedFormer for Android 4.0.5 (exactly that version):
  - Learners on slow mobile networks get their model. A Quran Lab server that is slow to connect is no longer given
    up for being slow: the SDK tries another beside it and goes on with whichever connects first, and a request has
    30 seconds. Offline, a call still fails at once. When no server connected in time, `TajweedError.cause.reason`
    is `connect_timeout` (apart from `network`).
  - A download that was cut goes on at the next start, and the attestation holds up on a flaky network.
  - A client closed while its `model()` call was still opening the model no longer leaves that model open, and the
    next client on the same storage opens it (4.0.2 could fail with `engine_failed`, `busy`). While another client's
    model is still closing, `model()` waits up to 3 seconds, off the main thread, and fails with `session_open` if it
    is still open then.
- **Flutter 3.41 or later.** The Android build now works in an app made by Flutter 3.41's template (AGP 8.11.1 with
  the Kotlin Gradle plugin 2.2.20, Gradle 8.14). 4.0.0 to 4.0.4 stopped there with `Unresolved reference: kotlin` in
  the plugin's `android/build.gradle.kts`, and 4.0.4 asked for Flutter 3.44 (its note that apps on 3.41 keep 4.0.3 was
  wrong: 4.0.3 stopped the same way). The plugin applies the Kotlin plugin itself only when the app's setup gives it
  no Kotlin, and builds as before with AGP 9 and its built-in Kotlin. `quranlab_tajweedformer_record` still needs
  Flutter 3.44, as the `record` package does.
- `TajweedClient.create` with a string that is not a Quran Lab key is `invalid_argument` before anything is sent.

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
