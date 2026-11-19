import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer_example/main.dart';

void main() {
  testWidgets('without a key the example says how to pass one', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();
    expect(find.textContaining('--dart-define=QURANLAB_KEY'), findsOneWidget);
    expect(find.text('Recite'), findsOneWidget);
  });
}
