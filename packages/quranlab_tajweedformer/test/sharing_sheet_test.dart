// The sheet, the card and the settings that Windows and Linux draw (lib/src/ffi/sharing_sheet.dart), held to the
// design's checks: every deck line of the sheet whole
// in all eight languages, the two buttons of the same height and width, the layout's direction the deck's, and the
// share label in a colour that reads on the app's accent. The decks are the contract's (test/fixtures/sharing_copy).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/ffi/sharing_sheet.dart';
import 'package:quranlab_tajweedformer/src/messages.g.dart';

SharingDeck deck(String lang) =>
    SharingDeck(jsonDecode(File('test/fixtures/sharing_copy/$lang.json').readAsStringSync()) as Map<String, Object?>);

Widget host(Widget child, {double width = 480, double height = 2400}) => MediaQuery(
      data: MediaQueryData(size: Size(width, height)),
      child: Directionality(textDirection: TextDirection.ltr, child: Center(child: SizedBox(width: width, child: child))),
    );

void main() {
  const langs = ['en', 'ar', 'id', 'ur', 'tr', 'ms', 'fr', 'bn'];
  final light = SharingTokens.of(SharingThemeMessage(), Brightness.light);

  for (final lang in langs) {
    testWidgets('$lang: every line of the sheet, whole; equal buttons; the deck\'s direction', (tester) async {
      tester.view.physicalSize = const Size(480, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final d = deck(lang);
      var shared = 0, notNow = 0;
      await tester.pumpWidget(host(SharingSheet(deck: d, tokens: light, onShare: () => shared++, onNotNow: () => notNow++)));
      for (final key in ['sheet.title', 'sheet.body', 'sheet.what', 'sheet.who', 'sheet.control', 'sheet.mistakes', 'sheet.share', 'sheet.not_now']) {
        expect(find.text(d[key]), findsOneWidget, reason: '$lang $key');
      }
      if (d.hadithVerified) {
        expect(find.text(d['sheet.hadith']), findsOneWidget);
        expect(find.text(d.arabicScript ? d['sheet.hadith_ref'] : d['sheet.hadith_ref'].toUpperCase()), findsOneWidget);
      }
      expect(find.text('Quran Lab'), findsOneWidget);
      final share = tester.getSize(find.ancestor(of: find.text(d['sheet.share']), matching: find.byType(Container)).first);
      final not = tester.getSize(find.ancestor(of: find.text(d['sheet.not_now']), matching: find.byType(Container)).first);
      expect(share, not);
      expect(share.height, greaterThanOrEqualTo(52));
      final dir = Directionality.of(tester.element(find.text(d['sheet.title'])));
      expect(dir, d.rtl ? TextDirection.rtl : TextDirection.ltr);
      expect(d.rtl, lang == 'ar' || lang == 'ur');
      await tester.tap(find.text(d['sheet.share']));
      await tester.tap(find.text(d['sheet.not_now']));
      expect((shared, notNow), (1, 1));
    });
  }

  testWidgets('the card: its line, two equal buttons, no yes', (tester) async {
    final d = deck('en');
    var opened = 0, notNow = 0;
    await tester.pumpWidget(host(SharingCard(deck: d, tokens: light, onOpen: () => opened++, onNotNow: () => notNow++)));
    expect(find.text(d['card.line']), findsOneWidget);
    expect(find.text(d['sheet.share']), findsNothing);
    final a = tester.getSize(find.ancestor(of: find.text(d['card.open']), matching: find.byType(Container)).first);
    final b = tester.getSize(find.ancestor(of: find.text(d['card.not_now']), matching: find.byType(Container)).first);
    expect(a, b);
    await tester.tap(find.text(d['card.open']));
    expect(opened, 1);
  });

  // SHARE_ASK_40 20.6, as the web SDK's card is held to it (test/v4/share_card_browser.test.mjs)
  for (final lang in langs) {
    testWidgets('$lang: the card in a wide window: at most 480 wide, one row of two equal buttons, a polite live region',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final d = deck(lang);
      await tester.pumpWidget(host(
          Align(alignment: Alignment.bottomCenter, child: SharingCard(deck: d, tokens: light, onOpen: () {}, onNotNow: () {})),
          width: 1600,
          height: 900));
      expect(tester.getSize(find.byType(SharingCard)).width, lessThanOrEqualTo(480));
      final open = find.ancestor(of: find.text(d['card.open']), matching: find.byType(Container)).first;
      final no = find.ancestor(of: find.text(d['card.not_now']), matching: find.byType(Container)).first;
      final (a, b) = (tester.getRect(open), tester.getRect(no));
      expect(a.size, b.size, reason: 'the same width and height');
      expect(a.top, b.top, reason: 'one row');
      expect(a.height, greaterThanOrEqualTo(44), reason: 'touch targets of 44 or more');
      // the open button first in the deck's reading direction
      expect(d.direction == TextDirection.rtl ? a.left > b.left : a.left < b.left, isTrue);
      expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.liveRegion == true), findsOneWidget);
    });
  }

  testWidgets('the settings: the switch is the learner\'s, the code only when opened, delete asks first', (tester) async {
    tester.view.physicalSize = const Size(480, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = deck('en');
    final actions = _Actions();
    await tester.pumpWidget(host(SharingSettings(deck: d, tokens: light, actions: actions, onClose: () {}), height: 1400));
    await tester.pumpAndSettle();
    expect(find.text(d['settings.toggle']), findsOneWidget);
    expect(find.text(actions.code), findsNothing);
    await tester.tap(find.text(d['recovery.reveal']));
    await tester.pumpAndSettle();
    expect(find.text(actions.code), findsOneWidget);
    expect(find.text(d['recovery.keep']), findsOneWidget);
    await tester.tap(find.text(d['settings.delete']));
    await tester.pumpAndSettle();
    expect(find.text(d['delete.confirm']), findsOneWidget);
    expect(actions.deleted, 0);
    await tester.tap(find.text(d['delete.action']));
    await tester.pumpAndSettle();
    expect(actions.deleted, 1);
    expect(find.text(d['delete.done']), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(d['settings.toggle']));
    await tester.pumpAndSettle();
    expect(actions.ons, [false]);
  });

  test('the share label reads on the accent: white on a dark accent, near-black on a light one', () {
    expect(SharingTokens.of(SharingThemeMessage(accent: 0xFF0E6B58), Brightness.light).onAccent, const Color(0xFFFFFFFF));
    expect(SharingTokens.of(SharingThemeMessage(accent: 0xFFFFD60A), Brightness.light).onAccent, const Color(0xFF0B0B0C));
    // the system's blue keeps a white label (3 to 1), and the stricter 4.5 when the system asks for more contrast
    expect(SharingTokens.of(SharingThemeMessage(accent: 0xFF007AFF), Brightness.light).onAccent, const Color(0xFFFFFFFF));
    expect(SharingTokens.of(SharingThemeMessage(accent: 0xFF007AFF), Brightness.light, highContrast: true).onAccent,
        const Color(0xFF0B0B0C));
    final t = SharingTokens.of(SharingThemeMessage(cornerRadius: 14), Brightness.dark);
    expect((t.sheetRadius, t.buttonRadius, t.cardRadius), (14, 7, 9));
    expect(t.background, const Color(0xFF1C1C1E));
  });
}

class _Actions implements SharingSettingsActions {
  final code = 'ABCD EFGH JKLM NPQR STUV WX';
  int deleted = 0;
  final ons = <bool>[];
  bool on = true;

  @override
  Future<SharingStateMessage> state() async => SharingStateMessage(available: true, on: on, recoveryCode: code);

  @override
  Future<void> setOn(bool on) async {
    ons.add(on);
    this.on = on;
  }

  @override
  Future<bool> deleteShared() async {
    deleted++;
    return true;
  }
}
