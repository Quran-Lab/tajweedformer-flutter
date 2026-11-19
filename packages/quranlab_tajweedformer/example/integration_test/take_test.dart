// The whole path on a device or emulator, with a real key and Quran Lab's servers (not run by CI: the CI machine
// has no device and never holds a model):
//   flutter test integration_test --dart-define=QURANLAB_KEY=qlk_v1_...
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

const key = String.fromEnvironment('QURANLAB_KEY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a sample clip goes through the whole path', (tester) async {
    if (key.isEmpty) {
      markTestSkipped('no key: pass --dart-define=QURANLAB_KEY=...');
      return;
    }
    final client = await TajweedClient.create(key);
    var progressed = false;
    final model = await client.model(onProgress: (done, total) => progressed = true);
    expect(model.sampleClips, isNotEmpty);
    final session =
        await model.listenFrom(model.sampleClips.first, options: const TajweedSessionOptions(pace: TajweedPace.fast));
    final events = <TajweedEvent>[];
    final eventsDone = session.events.forEach(events.add);
    final chunks = await session.chunks.toList();
    await eventsDone;
    expect(chunks, isNotEmpty);
    expect(chunks.last.decoded.isFinal, isTrue);
    expect(chunks.last.decoded.tokens, isNotEmpty);
    expect(events.last, isA<TajweedEnded>().having((e) => e.reason, 'reason', TajweedEndReason.sourceEnd));
    final heads = await session.finish();
    expect(heads.names, containsAll(TajweedSessionOptions.defaultHeads));
    expect(heads.decoded().text, chunks.last.decoded.text);
    final d = await client.diagnose();
    expect(d.modelVerified, isTrue);
    // ignore: avoid_print
    print('progress reported: $progressed; ${chunks.length} chunks; heard: ${heads.decoded().text}');
  });
}
