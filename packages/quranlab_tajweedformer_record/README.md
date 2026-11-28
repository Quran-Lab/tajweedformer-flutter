# quranlab_tajweedformer_record

An optional microphone for [quranlab_tajweedformer](https://pub.dev/packages/quranlab_tajweedformer): the
[record](https://pub.dev/packages/record) plugin captures 16 kHz mono 16-bit PCM, and this package pushes it into a
TajweedFormer take.

Most apps do not need it: `model.listen()` uses the native SDK's own microphone, with interruptions, route changes
and the end of a take in the background handled. Use this package when your app already captures audio with
`record`, wants to keep the recording itself, or runs on Windows or Linux, where the C SDK has no microphone
(`model.listen()` is `runtime_unsupported` there) and this is the plugin's microphone.

```dart
final mic = TajweedRecorder();
final session = await mic.start(model); // asks for the microphone; a refusal is microphone_denied
session.chunks.listen((chunk) => print(chunk.decoded.text));
// ...
final heads = await mic.stop(); // stops capturing and finishes the take
```

It runs wherever `record` and the plugin both run: Android, iOS, Windows, Linux and the web. `record` needs its own
platform setup: `NSMicrophoneUsageDescription` on iOS, `RECORD_AUDIO` on Android (the TajweedFormer SDK's manifest
already declares it), the learner's `pulseaudio-utils` (`parecord`, also under PipeWire) on Linux, and a page served
over https with `microphone=(self)` on the web.

Licence: NPL-1.3, as the plugin.
