// The pictures of the sheet, the card and the settings that Windows and Linux draw (lib/src/ffi/sharing_sheet.dart),
// for the release's review (the design's README: committed nowhere, attached to the review). It renders them with the
// fonts it is given, in English and Arabic, light and dark, at the default text size and a large one, and narrow; and
// the sheet and the card as a learner sees them over an app's window (the plugin's own layout, SharingUi), in the
// Windows runner's default window (1280 x 720) and a narrow one (420 x 760).
//
//   QL_DECKS=<contract>/sharing_copy QL_FONTS=<a folder of .ttf/.otf files> QL_OUT=<folder> \
//     flutter test tool/sharing_screens_test.dart
//
// Every font file in QL_FONTS is loaded as the default family's faces (their weights come from the files), so the
// pictures show the platform's own faces (Segoe UI on Windows, Noto on Linux).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/ffi/sharing_sheet.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/ffi/sharing_ui.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/messages.g.dart';

class _Actions implements SharingSettingsActions {
  _Actions(this.on, this.code);
  final bool on;
  final String? code;
  @override
  Future<SharingStateMessage> state() async => SharingStateMessage(available: true, on: on, recoveryCode: code);
  @override
  Future<void> setOn(bool on) async {}
  @override
  Future<bool> deleteShared() async => true;
}

void main() {
  final env = Platform.environment;
  final decks = env['QL_DECKS'], fonts = env['QL_FONTS'], out = env['QL_OUT'];
  final skip = decks == null || out == null ? 'set QL_DECKS and QL_OUT (and QL_FONTS)' : null;

  setUpAll(() async {
    if (skip != null) return;
    Directory(out!).createSync(recursive: true);
    if (fonts != null) {
      final loader = FontLoader('QLScreens');
      for (final f in Directory(fonts).listSync().whereType<File>().where((f) => RegExp(r'\.(ttf|otf)$', caseSensitive: false).hasMatch(f.path))) {
        loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      }
      await loader.load();
      sharingFontFamily = 'QLScreens';
    }
  });

  Future<void> shot(WidgetTester tester, String name, Widget child,
      {double width = 560, double height = 900, double textScale = 1, Brightness brightness = Brightness.light}) async {
    final key = GlobalKey();
    // real shadows, as an app draws them (flutter_test draws them as solid bands unless told otherwise)
    debugDisableShadows = false;
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: Size(width, height), devicePixelRatio: 2, textScaler: TextScaler.linear(textScale), platformBrightness: brightness),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: brightness == Brightness.dark ? const Color(0xFF0E0E10) : const Color(0xFFDADCE0),
            child: Padding(padding: const EdgeInsets.all(24), child: child),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    tester.view.reset();
    debugDisableShadows = true;
  }

  SharingDeck deck(String lang) => SharingDeck(jsonDecode(File('$decks/$lang.json').readAsStringSync()) as Map<String, Object?>);

  // a stand-in app screen behind the ask: a title bar and some rows, in the app's own light or dark
  Widget app(Brightness b) {
    final dark = b == Brightness.dark;
    final bg = dark ? const Color(0xFF121214) : const Color(0xFFF5F5F7), bar = dark ? const Color(0xFF1C1C1F) : const Color(0xFFFFFFFF);
    final row = dark ? const Color(0xFF2A2A2E) : const Color(0xFFE4E4E8);
    return ColoredBox(
      color: bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
            height: 56,
            color: bar,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.centerLeft,
            child: Text('Your app',
                style: TextStyle(fontFamily: sharingFontFamily, fontSize: 18, fontWeight: FontWeight.w600, color: dark ? const Color(0xFFF2F2F4) : const Color(0xFF17171A)))),
        for (var i = 0; i < 6; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Container(height: 48, decoration: BoxDecoration(color: row, borderRadius: BorderRadius.circular(10))),
          ),
      ]),
    );
  }

  Future<void> window(WidgetTester tester, String name, double width, double height, Brightness b, String lang,
      Widget Function(BuildContext context, SharingDeck d, SharingTokens t) layout) async {
    final key = GlobalKey();
    debugDisableShadows = false;
    tester.view.physicalSize = Size(width * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.platformBrightnessTestValue = b;
    final d = deck(lang);
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: Size(width, height), devicePixelRatio: 2, platformBrightness: b),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(fit: StackFit.expand, children: [
              app(b),
              Builder(builder: (context) => layout(context, d, SharingTokens.of(SharingThemeMessage(), b))),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    tester.view.reset();
    debugDisableShadows = true;
  }

  for (final (w, h, size) in [(1280.0, 720.0, 'default'), (420.0, 760.0, 'narrow')]) {
    for (final b in Brightness.values) {
      for (final lang in ['en', if (size == 'default' && b == Brightness.light) 'ar']) {
        testWidgets('window: the sheet, $lang, $size, ${b.name}', (tester) async {
          await window(tester, 'window_sheet_${lang}_${size}_${b.name}', w, h, b, lang,
              (context, d, t) => SharingUi.sheetLayout(context, d, t, onShare: () {}, onNotNow: () {}));
        }, skip: skip != null);
        testWidgets('window: the card, $lang, $size, ${b.name}', (tester) async {
          await window(tester, 'window_card_${lang}_${size}_${b.name}', w, h, b, lang,
              (context, d, t) => SharingUi.cardLayout(d, t, onOpen: () {}, onNotNow: () {}));
        }, skip: skip != null);
      }
    }
  }

  for (final lang in ['en', 'ar']) {
    for (final b in Brightness.values) {
      testWidgets('sheet $lang ${b.name}', (tester) async {
        final t = SharingTokens.of(SharingThemeMessage(), b);
        await shot(tester, 'sheet_${lang}_${b.name}',
            Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: SharingSheet(deck: deck(lang), tokens: t, onShare: () {}, onNotNow: () {}))),
            height: 1400, brightness: b);
      }, skip: skip != null);
    }
    testWidgets('card $lang', (tester) async {
      final t = SharingTokens.of(SharingThemeMessage(), Brightness.light);
      await shot(tester, 'card_$lang',
          Align(alignment: Alignment.bottomCenter, child: SharingCard(deck: deck(lang), tokens: t, onOpen: () {}, onNotNow: () {})),
          height: 420);
    }, skip: skip != null);
    testWidgets('settings $lang', (tester) async {
      final t = SharingTokens.of(SharingThemeMessage(), Brightness.light);
      await shot(tester, 'settings_$lang',
          Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: SharingSettings(deck: deck(lang), tokens: t, actions: _Actions(true, 'ABCD EFGH JKLM NPQR STUV WX'), onClose: () {}))),
          height: 700);
    }, skip: skip != null);
  }
  testWidgets('sheet en at a large text size', (tester) async {
    await shot(tester, 'sheet_en_large',
        Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: SharingSheet(deck: deck('en'), tokens: SharingTokens.of(SharingThemeMessage(), Brightness.light), onShare: () {}, onNotNow: () {}))),
        height: 1100, textScale: 1.6);
  }, skip: skip != null);
  testWidgets('sheet en narrow (320)', (tester) async {
    await shot(tester, 'sheet_en_narrow',
        SharingSheet(deck: deck('en'), tokens: SharingTokens.of(SharingThemeMessage(), Brightness.light), onShare: () {}, onNotNow: () {}),
        width: 368, height: 1000);
  }, skip: skip != null);
  testWidgets('sheet en with an app theme (a blue accent, radius 16)', (tester) async {
    final t = SharingTokens.of(SharingThemeMessage(accent: 0xFF0A66FF, cornerRadius: 16), Brightness.light);
    await shot(tester, 'sheet_en_themed',
        Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: SharingSheet(deck: deck('en'), tokens: t, onShare: () {}, onNotNow: () {}))),
        height: 1400);
  }, skip: skip != null);
}
