// The quick start shown in the README: the four calls of every Quran Lab SDK. CI compiles it (flutter analyze and
// the example's build), and the README's block must be exactly the lines between the two markers.
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

// README:begin
Future<void> quickStart(void Function(String heard) show) async {
  final client = await TajweedClient.create('qlk_v1_...'); // your key from sdk.quranlab.ai; one client per process
  final model = await client.model(); // the first call downloads and verifies the model
  final session = await model.listen( // the SDK's own microphone: it asks for the permission itself
      options: const TajweedSessionOptions(endOnSilenceMs: 1500));
  await for (final chunk in session.chunks) { // every 320 ms, until 1.5 s of silence end the take
    show(chunk.decoded.text); // what the model heard so far
  }
}
// README:end
