# Changelog

## 4.0.0

The first release on pub.dev (2026-11-19): `quranlab_tajweedformer` 4.0.0, one Flutter plugin for Android and iOS
over TajweedFormer for Android 4.0 (Maven Central) and TajweedFormer for iOS and macOS 4.0 (Swift package), through
their public API only, and `quranlab_tajweedformer_record` 4.0.0, an optional microphone. The plugin's version
follows the SDKs it wraps. Moving an app from the native 3.x SDKs: [docs/migrating-to-4.md](docs/migrating-to-4.md).

- **The model is protected.** It is encrypted from Quran Lab's server to the device and runs only inside the Quran
  Lab Core, under a lease for each install. Learners keep working offline for days at a time (the exact time is set
  by Quran Lab and may change); when the lease has ended and Quran Lab cannot be reached, the model keeps opening for
  24 hours more, and a refusal ends that at once.
- **The Dart API of the native SDKs:** `TajweedClient`, `TajweedModel`, `TajweedSession`, `TajweedHeads`,
  `TajweedBackend`, the decoded layer, the events, and one error type, `TajweedError`, with the SDKs' codes.
- **Three ways to feed a take:** the SDK's own microphone (`model.listen()`), the app's audio (`model.session()`
  and `push` or `pushInt16`), and the model's sample clips. `quranlab_tajweedformer_record` captures the microphone
  with the `record` plugin.
- **Every learner is asked** and the choice is theirs: Not now, stop, or delete at any time. Every app shows the same
  sharing sheet; there is no `audience` option and no switch for the app.
- **Android: add your app's signing certificates** on your Android key's page at sdk.quranlab.ai for
  hardware-verified installs. At launch every Android phone runs the CPU engine.
- **iOS: add the App Attest capability** for hardware-verified installs, the Neural Engine and sharing uploads.
  Without it the SDK still runs, on the CPU engine only. The plugin needs Flutter's Swift Package Manager
  integration. The model downloads when the app calls `client.model()` or `client.prefetch()`.
- **Error codes and reports.** `needsConnection` only when no request got an answer. Every error your app gets, and
  every failure the SDKs go on from, reaches Quran Lab as a small anonymous report on your app's Problems page.
- **The anonymous analytics are always on**, with no option.
- **Model versions.** From V4.1 on, new model versions are published only encrypted, for SDK 4.0.

History: a 1.0.0 over the 3.x SDKs was built and never published; its API is the one above.
