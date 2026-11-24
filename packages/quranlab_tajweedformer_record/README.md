# quranlab_tajweedformer_record

An optional microphone for [quranlab_tajweedformer](https://pub.dev/packages/quranlab_tajweedformer): the
[record](https://pub.dev/packages/record) plugin captures 16 kHz mono 16-bit PCM, and this package pushes it into a
TajweedFormer take.

Most apps do not need it: `model.listen()` uses the native SDK's own microphone, with interruptions, route changes
and the end of a take in the background handled. Use this package when your app already captures audio with
`record`, or wants to keep the recording itself.

```dart
final mic = TajweedRecorder();
final session = await mic.start(model); // asks for the microphone; a refusal is microphone_denied
session.chunks.listen((chunk) => print(chunk.decoded.text));
// ...
final heads = await mic.stop(); // stops capturing and finishes the take
```

`record` needs its own platform setup: `NSMicrophoneUsageDescription` on iOS, `RECORD_AUDIO` on Android (the
TajweedFormer SDK's manifest already declares it).

Licence: NPL-1.3, as the plugin.
