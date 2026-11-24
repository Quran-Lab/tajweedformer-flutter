# TajweedFormer for Flutter

TajweedFormer V4 for Flutter on Android and iOS: recitation audio in, the model's output out while the learner
recites. On the device, offline after the first download, and free. One plugin over Quran Lab's native SDKs 4.0:
Maven `ai.quranlab:tajweedformer` on Android and the Swift package `tajweedformer-apple` on iOS.

## Install

```sh
flutter pub add quranlab_tajweedformer
```

## Before you start

| | |
| - | - |
| **Key** | An apps key from [sdk.quranlab.ai](https://sdk.quranlab.ai) for your app's Android package name and iOS bundle id. |
| **Flutter** | 3.41 or later. On iOS the app uses Flutter's Swift Package Manager integration (on by default since 3.44): the Apple SDK is a Swift package only. |
| **Android** | Android 8.0 (API 26) or later: `minSdk = 26`. Phones and tablets are `arm64-v8a` and `armeabi-v7a`; `x86_64` runs the CPU engine on emulators, with a development key only. Add your signing certificates on the key's page for hardware-verified installs. |
| **iOS** | iOS 15 or later on Apple silicon, Xcode 16. `NSMicrophoneUsageDescription` in `Info.plist`. The App Attest capability, for hardware-verified installs, the Neural Engine and shared recordings. A development key on the Simulator. |
| **Download** | The first `client.model()` downloads the model, about 56 MB once, encrypted for the install. After that the model works offline, and the SDK keeps itself up to date in the background when the device is online. If Quran Lab's main servers can't be reached, the SDK uses backup servers automatically. |
| **Takes** | A model runs one take at a time; a take holds at most 20 minutes of audio. |

## Quick start

```dart
Future<void> quickStart(void Function(String heard) show) async {
  final client = await TajweedClient.create('qlk_v1_...'); // your key from sdk.quranlab.ai; one client per process
  final model = await client.model(); // the first call downloads and verifies the model
  final session = await model.listen( // the SDK's own microphone: it asks for the permission itself
      options: const TajweedSessionOptions(endOnSilenceMs: 1500));
  await for (final chunk in session.chunks) { // every 320 ms, until 1.5 s of silence end the take
    show(chunk.decoded.text); // what the model heard so far
  }
}
```

These are the four calls of every Quran Lab SDK: client, model, listen, read. Each chunk carries the raw heads you
selected (`chunk.heads`) and the decoded layer of the take so far (`chunk.decoded`: the text, each token with its
times and confidence, and how many tokens are settled). `session.finish()` ends a take and returns its heads.
Every failure is a `TajweedError` with the native SDK's `code`, `message`, `fix` and `docs` link, and its `cause`
(where and why it failed; on `needs_connection`, `cause.needs` is `model` when the model files are not on the device
yet, `lease` when the model is on the device and needs Quran Lab's answer to open).

- **Your own audio:** `model.session()` and `session.pushInt16(...)` or `session.push(...)` replace `listen()`.
  The optional package `quranlab_tajweedformer_record` captures the microphone with the `record` plugin.
- **No microphone:** `model.listenFrom(model.sampleClips.first)` runs a sample recitation through the same path.
- **Recitation sharing:** the SDK shows Quran Lab's own consent sheet; every learner is asked, the choice is theirs,
  and there is nothing to switch on or off. `client.sharing.openSettings()` shows the learner's settings.
- **Analytics and error reports** are anonymous and always on, with no option; only Quran Lab can switch them off.
- **A teacher notice** is up to you and encouraged, for example: "Automatic tajweed feedback can be wrong. It does
  not replace a qualified teacher."

The full reference (every type, the events, sharing, the two platforms, building and testing) is in the
repository's [AGENTS.md](https://github.com/Quran-Lab/tajweedformer-flutter/blob/main/AGENTS.md), written for coding
assistants and just as readable for you. Guides: [sdk.quranlab.ai/docs](https://sdk.quranlab.ai/docs).

## Licence

Quran Lab is a waqf: the SDKs and the models are free to use and are never sold. The source code and the
TajweedFormer model weights are released under the Quran-Lab No-Profit License 1.3 (NPL-1.3): use the SDK, copy and modify its source code, and build apps with them freely, but never charge for them, for access to them, or for any feature they power. Neither they nor their outputs may be used to train other models, and the model is used only through the SDK: never extracted, converted, re-hosted or bundled.
