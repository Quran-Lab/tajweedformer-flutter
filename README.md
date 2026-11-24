<h1 align="center">TajweedFormer for Flutter</h1>

<p align="center">TajweedFormer V4 for Flutter on Android and iOS: recitation audio in, the model's output out while the learner recites. On the device, offline, and free.</p>

<p align="center">
  <img alt="platform: Android, iOS" src="https://img.shields.io/badge/platform-Android%20%7C%20iOS-1c1b19?style=flat-square">
  <img alt="version: 4.0.3" src="https://img.shields.io/badge/version-4.0.3-2a3b8f?style=flat-square">
  <img alt="model licence: NPL-1.3" src="https://img.shields.io/badge/model%20licence-NPL--1.3-1c1b19?style=flat-square">
</p>

## What you get

<table>
<tr>
<td width="33%" valign="top">

**Hears the recitation**<br>Streaming recognition of Quranic recitation: audio in, and what the model heard comes out as often as every 160 ms on the CPU engine (320 ms by default, including on the Neural Engine and the NPU; 480 ms for longer context).

</td>
<td width="33%" valign="top">

**Every output of the model**<br>The sounds it heard with confidence and timing, and every head of the network per chunk (lengthening, gemination, ghunna, qalqalah and more): yours to build on.

</td>
<td width="33%" valign="top">

**One plugin, two platforms**<br>A Dart API over the native Android and iOS SDKs, with their names. It runs on the CPU on every device, and on the Neural Engine or the NPU where the device's build passes its self-test.

</td>
</tr>
<tr>
<td valign="top">

**Private by default**<br>Offline, on the device. A recording leaves it only when the learner agrees to share it.

</td>
<td valign="top">

**Nothing to host**<br>The SDK downloads the right model for each device (56.5 MB to start) from Quran Lab's servers, verifies it and keeps it up to date.

</td>
<td valign="top">

**Data for your own judge**<br>The SDK scores nothing. The model's thresholds come with it as read-only data, so your app can judge a recitation its own way. The expected units of each ayah do not: with this release and the model build served now, `model.reference` is null.

</td>
</tr>
</table>

## Why TajweedFormer

- **Made for the Quran.** Trained on Quranic recitation, with its own sound units and heads for what tajweed is about.
- **Feedback in the moment.** Output streams while the learner recites, so your app can respond on the word itself, not after the take.
- **One engine on every platform.** The same engine runs the [Android](https://github.com/Quran-Lab/tajweedformer-android), [iOS and macOS](https://github.com/Quran-Lab/tajweedformer-apple), [web](https://github.com/Quran-Lab/tajweedformer-web) and [Windows and Linux](https://github.com/Quran-Lab/tajweedformer-c) SDKs, all set from one portal.
- **Free, and it stays free.** Quran Lab is a non-profit waqf: the SDKs and models are never sold. The licence, NPL-1.3, and Quran Lab's access terms ask three things: no paywall on model features, no output presented as an authoritative religious ruling, and no training of other models on the model or its outputs. A line telling learners that automatic feedback can be wrong is encouraged, not required.

## Built for AI developers

Copy the setup prompt from [sdk.quranlab.ai](https://sdk.quranlab.ai/go/gh-tajweedformer-flutter) and paste it into your coding assistant. That one prompt sets everything up: the package, your key, and the first calls. [AGENTS.md](AGENTS.md), beside this README, gives the assistant the complete API, so the code it writes uses names that exist. Prefer to do it by hand? Get a key in the portal and start below.

## Install

```sh
flutter pub add quranlab_tajweedformer
```

Flutter 3.41 or later. On iOS the app uses Flutter's Swift Package Manager integration (on by default since Flutter
3.44): the Apple SDK ships only as a Swift package.

## Before you start

| | |
| - | - |
| **Key** | An apps key from [sdk.quranlab.ai](https://sdk.quranlab.ai/go/gh-tajweedformer-flutter) for your app's Android package name and iOS bundle id. On the Android emulator and the iOS Simulator, a development key: Quran Lab leases the Core's emulator and Simulator builds to development keys only. |
| **Android** | Android 8.0 (API 26) or later: `minSdk = 26`. Phones and tablets are `arm64-v8a` and `armeabi-v7a`; `x86_64` runs the CPU engine only, on the emulator and x86 Chromebooks. The plugin brings `ai.quranlab:tajweedformer:4.0.2`; do not add it yourself. On your key's page, under "Signing certificates (SHA-256)", add the app signing key certificate and the upload key certificate: until you do, your installs are not hardware-verified for your app. At 4.0's launch every phone runs the Core's CPU engine. |
| **iOS** | iOS 15 or later on Apple silicon (devices and the arm64 simulator), Xcode 16 or later, and Flutter's Swift Package Manager integration (the Apple SDK ships only as a Swift package). `NSMicrophoneUsageDescription` in `Info.plist`. The App Attest capability: with it an install is hardware-verified, may use the Neural Engine, and uploads shared recordings. Exclude x86_64 from Simulator builds (`EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`): the Core is arm64 only. |
| **Download** | Making the client downloads nothing. The first `client.model()` or `client.prefetch()` downloads the model, encrypted: 56.5 MB, once (73.8 MB on disk), and needs a connection. |
| **Offline** | The first `client.model()` or `client.prefetch()` needs a connection; after that the model works offline, and the SDK keeps itself up to date in the background when the device is online. `needs_connection` means the SDK needs Quran Lab to continue. A model that is open keeps running. |
| **Model** | The model runs only inside the Quran Lab Core, which comes with the native SDKs: its files are encrypted from Quran Lab's server to the device, and no plain model file is ever written. When Quran Lab refuses the key or the app, the model's files are removed. |
| **Analytics** | Anonymous counts and durations (never audio, text, names or device identifiers) and reports of the failures your learners hit are always sent; you find them at sdk.quranlab.ai under your app, Problems included. |
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

These are the four calls of every Quran Lab SDK: client, model, listen, read. The code is
[`example/lib/quick_start.dart`](packages/quranlab_tajweedformer/example/lib/quick_start.dart), which CI compiles.
The example app beside it ([`example/lib/main.dart`](packages/quranlab_tajweedformer/example/lib/main.dart)) is
one screen around those calls: the model loading with its download progress, "Play sample" (a sample clip, no
microphone), "Recite", the tokens as they come (tentative ones dimmed), "Stop", "Diagnose" and the sharing
settings. Run it with a key made for its identifiers (`ai.quranlab.tajweedformer.flutter.example` on both
platforms): `flutter run --dart-define=QURANLAB_KEY=qlk_v1_...`. To run it as another app id that your key names,
set `QURANLAB_APPLICATION_ID` for the Android build. On the Android emulator and the iOS Simulator use a development
key: Quran Lab leases the Core's emulator and Simulator builds to development keys only.

- **The microphone.** `model.listen()` asks for the permission when it has to (a refusal is the error
  `microphone_denied`), captures at the device's own rate and carries that rate to the take. No sample rate
  appears in your code. iOS needs `NSMicrophoneUsageDescription` in `Info.plist`.
- **The end of a take.** With `endOnSilenceMs` (500 to 60000) the take finishes by itself after that much silence
  following speech: the last chunk has `decoded.isFinal`, `chunks` ends, and `session.finish()` returns the take's
  heads. Silence is what the model hears as silence (a held vowel is speech), so in a noisy room a take may not end
  on silence: keep a Stop button that calls `session.finish()`. A take holds at most 20 minutes of audio.
- **Background.** A `listen` take ends when the app leaves the foreground (`TajweedEnded(background)`); start a new
  one when the app comes back.

## More

The full reference (every layer of the API, backends, what a device downloads, platform settings, recording sharing, building and testing) is in [AGENTS.md](AGENTS.md), written for coding assistants and just as readable for you. Guides: [sdk.quranlab.ai/docs](https://sdk.quranlab.ai/go/gh-tajweedformer-flutter?to=/docs).

## Problems and wishes

Something does not work, something is missing, or you want to tell us how it went:
[open an issue](https://github.com/Quran-Lab/tajweedformer-flutter/issues/new/choose). There is a form for a bug, one for a
wish and one for a word of feedback. Issues are public, so leave out keys and anything that came from a learner.
A security problem does not go into an issue: use "Report a vulnerability" on the
[Security tab](https://github.com/Quran-Lab/tajweedformer-flutter/security). A coding assistant can file an issue for you; it
shows you the text first.

## Licence

Quran Lab is a waqf: the SDKs and the models are free to use and are never sold.

The source code in this repository and the TajweedFormer model weights are released under the
Quran-Lab No-Profit License 1.3 ([NPL-1.3](LICENSE)): use, copy, modify and build apps on them freely,
but never charge for them, for access to them, or for any feature they power. Neither they nor their outputs may be used to train other models. The weights are not
stored in this repository; Quran Lab hosts them itself and serves them to apps by
`cdn.quranlab.ai/models` under the same licence. Get access at
[sdk.quranlab.ai](https://sdk.quranlab.ai/go/gh-tajweedformer-flutter).

Third-party components keep their own licences, listed in their folders under `third_party/`.
