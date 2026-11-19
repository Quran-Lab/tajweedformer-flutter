## 4.0.0

The first release on pub.dev (2026-11-19): one Flutter plugin for Android and iOS over TajweedFormer for Android 4.0
(Maven Central, `ai.quranlab:tajweedformer`) and TajweedFormer for iOS and macOS 4.0 (Swift package,
`tajweedformer-apple`), through their public API only. Its version follows the SDKs it wraps.

- The model is encrypted from Quran Lab's server to the device and runs only inside the Quran Lab Core, under a lease
  for each install. Learners keep working offline for days at a time, set by Quran Lab; when the lease has ended and
  Quran Lab cannot be reached, the model keeps opening for 24 hours more, and a refusal ends that at once.
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
- `client.diagnose().protectedModel`: the install's key store and the lease the Core holds (`valid`, `grace`,
  `expired`, `stopped`, `none`), its class (`attested` or `standard`), end, refresh time and grace end.
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
