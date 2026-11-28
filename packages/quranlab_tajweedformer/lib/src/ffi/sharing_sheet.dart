// The SDK's sharing sheet, its re-ask card and its settings, drawn in Flutter for Windows and Linux (the C SDK has
// no UI). The words are the copy deck's (the C SDK's, with the app's own wording); the look is the contract's
// (sharing_copy/design/README.md): the same structure, tokens and rules as the Apple, Android and web sheets, as a
// centred card at most 480 wide on a desktop window. Widgets only: the sheet needs nothing of the app's Material
// setup (its icons are drawn here, not taken from an icon font). Internal.
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../messages.g.dart';

/// The deck as the sheet reads it: its strings, direction, language and whether the hadith is verified.
class SharingDeck {
  SharingDeck(Map<String, Object?> json)
      : strings = ((json['strings'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        rtl = json['dir'] == 'rtl',
        lang = json['lang'] as String? ?? 'en',
        hadithVerified = (json['hadith_source'] as Map?)?['verified_at'] != null;

  final Map<String, String> strings;
  final bool rtl;
  final String lang;
  final bool hadithVerified;

  String operator [](String key) => strings[key] ?? '';
  bool has(String key) => (strings[key] ?? '').isNotEmpty;

  /// Arabic and Urdu: the system's Arabic face, taller lines, no negative tracking, no upper case.
  bool get arabicScript => lang == 'ar' || lang == 'ur' || lang.startsWith('ar-') || lang.startsWith('ur-');

  TextDirection get direction => rtl ? TextDirection.rtl : TextDirection.ltr;
}

/// The tokens of the design, for light or dark, with the app's theme applied.
class SharingTokens {
  factory SharingTokens.of(SharingThemeMessage theme, Brightness platform, {bool highContrast = false}) {
    final dark = theme.dark ?? platform == Brightness.dark;
    Color? c(int? argb) => argb == null ? null : Color(argb);
    final bg = c(theme.background) ?? (dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF));
    final text = c(theme.text) ?? (dark ? const Color(0xFFF4F4F6) : const Color(0xFF17171A));
    final accent = c(theme.accent) ?? (dark ? const Color(0xFF62D2B6) : const Color(0xFF0E6B58));
    final tint = Color.alphaBlend(accent.withValues(alpha: dark ? 0.16 : 0.11), bg);
    final soft = Color.alphaBlend(accent.withValues(alpha: dark ? 0.08 : 0.06), bg);
    final card = dark ? const Color(0xFF2A2A2D) : const Color(0xFFF4F4F6);
    // contrast (1.12.2): white on the accent when it has 3 to 1 (4.5 when the system asks for more contrast), else
    // near-black; the accent's labels and marks in the accent when it has that against what is behind them, else in
    // the text colour
    final bar = highContrast ? 4.5 : 3.0;
    return SharingTokens._(
      dark: dark,
      background: bg,
      text: text,
      body: c(theme.text) ?? (dark ? const Color(0xFFD2D2D8) : const Color(0xFF3D3D44)),
      secondary: c(theme.secondaryText) ?? (dark ? const Color(0xFFA7A7B0) : const Color(0xFF62626B)),
      card: card,
      divider: dark ? const Color(0xFF3B3B40) : const Color(0xFFE4E4E9),
      barDivider: dark ? const Color(0xFF2E2E32) : const Color(0xFFECECF0),
      switchOff: dark ? const Color(0xFF48484D) : const Color(0xFFD4D4DA),
      accent: accent,
      onAccent: contrast(const Color(0xFFFFFFFF), accent) >= bar ? const Color(0xFFFFFFFF) : const Color(0xFF0B0B0C),
      tint: tint,
      soft: soft,
      notNowLabel: contrast(accent, tint) >= bar ? accent : text,
      icon: contrast(accent, card) >= bar ? accent : text,
      glyph: contrast(accent, tint) >= bar ? accent : text,
      // the sheet's radius; the buttons' (14) and the cards' (18) scale with it
      scale: (theme.cornerRadius ?? 28) / 28,
    );
  }

  const SharingTokens._({
    required this.dark,
    required this.background,
    required this.text,
    required this.body,
    required this.secondary,
    required this.card,
    required this.divider,
    required this.barDivider,
    required this.switchOff,
    required this.accent,
    required this.onAccent,
    required this.tint,
    required this.soft,
    required this.notNowLabel,
    required this.icon,
    required this.glyph,
    required this.scale,
  });

  final bool dark;
  final Color background, text, body, secondary, card, divider, barDivider, switchOff, accent, onAccent, tint, soft;
  final Color notNowLabel, icon, glyph;
  final double scale;

  double get sheetRadius => 28 * scale;
  double get buttonRadius => 14 * scale;
  double get cardRadius => 18 * scale;

  /// The WCAG contrast ratio of two colours.
  static double contrast(Color a, Color b) {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    final x = lum(a), y = lum(b);
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
  }
}

/// Tests only: the font the pictures of the sheet are drawn in (null: the platform's own, as in an app).
String? sharingFontFamily;

TextStyle _style(SharingDeck d, double size, double line, FontWeight w, Color c, {double latinTracking = 0, double? arabicLine}) =>
    TextStyle(
      inherit: false,
      fontFamily: sharingFontFamily,
      fontSize: size,
      height: (d.arabicScript ? (arabicLine ?? line) : line) / size,
      fontWeight: w,
      color: c,
      letterSpacing: d.arabicScript ? 0 : latinTracking * size,
      decoration: TextDecoration.none,
      textBaseline: TextBaseline.alphabetic,
    );

// ---- the marks (decoration, hidden from screen readers) ----

enum SharingMark { wave, mic, shield, toggle, chevronDown, chevronUp, close }

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.mark, this.color);
  final SharingMark mark;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (mark) {
      case SharingMark.wave:
        // five vertical strokes, the waveform glyph
        const h = [6.0, 12.0, 18.0, 12.0, 6.0];
        for (var i = 0; i < 5; i++) {
          final x = 4.0 + i * 4;
          canvas.drawLine(Offset(x, 12 - h[i] / 2), Offset(x, 12 + h[i] / 2), stroke);
        }
      case SharingMark.mic:
        canvas.drawRRect(RRect.fromLTRBR(9, 3, 15, 14, const Radius.circular(3)), stroke);
        canvas.drawPath(
            Path()
              ..moveTo(6, 11)
              ..cubicTo(6, 15, 8.7, 17.5, 12, 17.5)
              ..cubicTo(15.3, 17.5, 18, 15, 18, 11),
            stroke);
        canvas.drawLine(const Offset(12, 17.5), const Offset(12, 21), stroke);
      case SharingMark.shield:
        canvas.drawPath(
            Path()
              ..moveTo(12, 3)
              ..lineTo(19, 6)
              ..lineTo(19, 11)
              ..cubicTo(19, 15.5, 16, 19, 12, 21)
              ..cubicTo(8, 19, 5, 15.5, 5, 11)
              ..lineTo(5, 6)
              ..close(),
            stroke);
        canvas.drawPath(
            Path()
              ..moveTo(9, 12)
              ..lineTo(11.2, 14.2)
              ..lineTo(15.2, 10),
            stroke);
      case SharingMark.toggle:
        canvas.drawRRect(RRect.fromLTRBR(3, 7, 21, 17, const Radius.circular(5)), stroke);
        canvas.drawCircle(const Offset(16, 12), 2.6, Paint()..color = color);
      case SharingMark.chevronDown || SharingMark.chevronUp:
        final up = mark == SharingMark.chevronUp;
        canvas.drawPath(
            Path()
              ..moveTo(7, up ? 14.5 : 9.5)
              ..lineTo(12, up ? 9.5 : 14.5)
              ..lineTo(17, up ? 14.5 : 9.5),
            stroke);
      case SharingMark.close:
        canvas.drawLine(const Offset(6.5, 6.5), const Offset(17.5, 17.5), stroke);
        canvas.drawLine(const Offset(17.5, 6.5), const Offset(6.5, 17.5), stroke);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.mark != mark || old.color != color;
}

class _Mark extends StatelessWidget {
  const _Mark(this.mark, this.color);
  final SharingMark mark;
  final Color color;
  static const size = 22.0;

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: CustomPaint(size: Size.square(size), painter: _MarkPainter(mark, color)));
}

// ---- the pieces ----

/// A tappable area with a focus ring, for the keyboard as for the pointer.
class _Tap extends StatefulWidget {
  const _Tap({required this.onTap, required this.child, this.radius = 0, this.focusColor, this.label, this.button = true});
  final VoidCallback? onTap;
  final Widget child;
  final double radius;
  final Color? focusColor;
  final String? label;
  final bool button;

  @override
  State<_Tap> createState() => _TapState();
}

class _TapState extends State<_Tap> {
  bool _focus = false, _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return Semantics(
      button: widget.button,
      enabled: on,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: on,
        mouseCursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap?.call())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              color: _hover && on ? const Color(0x0F000000) : null,
              border: _focus ? Border.all(color: widget.focusColor ?? const Color(0xFF3D7BFF), width: 2) : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// The header: the emblem and the name `Quran Lab`, always in Latin letters, left to right inside its row.
class _Header extends StatelessWidget {
  const _Header(this.t);
  final SharingTokens t;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: t.tint, borderRadius: BorderRadius.circular(12)),
              child: _Mark(SharingMark.wave, t.glyph),
            ),
          ),
          const SizedBox(width: 10),
          Text('Quran Lab',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                  inherit: false,
                  fontFamily: sharingFontFamily,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.01 * 15,
                  color: t.text,
                  decoration: TextDecoration.none)),
        ],
      );
}

/// Two equal buttons: the filled one and the tinted one, same size, shape and type (principle 5).
class _Buttons extends StatelessWidget {
  const _Buttons(this.d, this.t,
      {required this.primary, required this.secondary, required this.onPrimary, required this.onSecondary, this.row = false});
  final SharingDeck d;
  final SharingTokens t;
  final String primary, secondary;
  final VoidCallback onPrimary, onSecondary;

  /// In one row (the card) instead of stacked (the sheet).
  final bool row;

  Widget _button(String label, Color fill, Color fg, VoidCallback onTap) => _Tap(
        onTap: onTap,
        radius: t.buttonRadius,
        focusColor: t.text,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          width: double.infinity,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(t.buttonRadius)),
          child: Text(label, textAlign: TextAlign.center, maxLines: 2, style: _style(d, 16, 20, FontWeight.w600, fg)),
        ),
      );

  @override
  Widget build(BuildContext context) => row
      // the card: one row, the two of the same width and height (the taller label sets both)
      ? IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _button(primary, t.accent, t.onAccent, onPrimary)),
            const SizedBox(width: 10),
            Expanded(child: _button(secondary, t.tint, t.notNowLabel, onSecondary)),
          ]),
        )
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(primary, t.accent, t.onAccent, onPrimary),
            const SizedBox(height: 10),
            _button(secondary, t.tint, t.notNowLabel, onSecondary),
          ],
        );
}

/// A panel in the sheet's background and radius, with Escape as [onEscape].
class _Panel extends StatelessWidget {
  const _Panel({required this.t, required this.d, required this.onEscape, required this.child, this.shadow = false});
  final SharingTokens t;
  final SharingDeck d;
  final VoidCallback onEscape;
  final Widget child;
  final bool shadow;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: d.direction,
        child: Shortcuts(
          shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
          child: Actions(
            actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => onEscape())},
            child: FocusScope(
              autofocus: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: t.background,
                  borderRadius: BorderRadius.circular(t.sheetRadius),
                  boxShadow: shadow ? const [BoxShadow(color: Color(0x40000000), blurRadius: 30, offset: Offset(0, 10))] : null,
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(t.sheetRadius), child: child),
              ),
            ),
          ),
        ),
      );
}

Widget _line(Color c) => SizedBox(height: 1, width: double.infinity, child: ColoredBox(color: c));

/// The consent sheet: the header, the title, the body, the disclosure card, the hadith (when the deck says it is
/// verified), the mistakes line, and the bar with the two buttons, which does not scroll.
class SharingSheet extends StatelessWidget {
  const SharingSheet({super.key, required this.deck, required this.tokens, required this.onShare, required this.onNotNow});

  final SharingDeck deck;
  final SharingTokens tokens;
  final VoidCallback onShare, onNotNow;

  @override
  Widget build(BuildContext context) {
    final d = deck, t = tokens;
    final body = _style(d, 15.5, 24, FontWeight.w400, t.body, arabicLine: 27);
    Widget row(SharingMark mark, String key) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: _Mark(mark, t.icon)),
                const SizedBox(width: 12),
                Expanded(child: Text(d[key], style: _style(d, 14.5, 22, FontWeight.w400, t.text, arabicLine: 25))),
              ],
            ),
          ),
        );
    final blocks = <Widget>[
      _Header(t),
      const SizedBox(height: 14),
      Semantics(
          header: true,
          child: Text(d['sheet.title'], style: _style(d, 26, 31, FontWeight.w700, t.text, latinTracking: -0.02, arabicLine: 36))),
      const SizedBox(height: 18),
      Text(d['sheet.body'], style: body),
      const SizedBox(height: 18),
      // the disclosure, whole, never shortened
      DecoratedBox(
        decoration: BoxDecoration(color: t.card, borderRadius: BorderRadius.circular(t.cardRadius)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            row(SharingMark.mic, 'sheet.what'),
            _line(t.divider),
            row(SharingMark.shield, 'sheet.who'),
            _line(t.divider),
            row(SharingMark.toggle, 'sheet.control'),
          ]),
        ),
      ),
      if (d.hadithVerified && d.has('sheet.hadith')) ...[
        const SizedBox(height: 18),
        DecoratedBox(
          decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(t.cardRadius)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d['sheet.hadith'], style: _style(d, 15, 24, FontWeight.w400, t.text, arabicLine: 28)),
              const SizedBox(height: 10),
              Text(d.arabicScript ? d['sheet.hadith_ref'] : d['sheet.hadith_ref'].toUpperCase(),
                  style: _style(d, 12, 16, FontWeight.w600, t.secondary, latinTracking: 0.06)),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 18),
      Text(d['sheet.mistakes'], style: _style(d, 15, 24, FontWeight.w400, t.body, arabicLine: 27)),
      const SizedBox(height: 22),
    ];
    return _Panel(
      t: t,
      d: d,
      onEscape: onNotNow,
      shadow: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _FadedScroll(
              background: t.background,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks),
              ),
            ),
          ),
          _line(t.barDivider),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
            child: _Buttons(d, t, primary: d['sheet.share'], secondary: d['sheet.not_now'], onPrimary: onShare, onSecondary: onNotNow),
          ),
        ],
      ),
    );
  }
}

/// The column scrolls under the bar; while text remains below, a 40 point fade of the sheet's background sits above
/// the bar so it does not end on a hard edge.
class _FadedScroll extends StatefulWidget {
  const _FadedScroll({required this.background, required this.child});
  final Color background;
  final Widget child;

  @override
  State<_FadedScroll> createState() => _FadedScrollState();
}

class _FadedScrollState extends State<_FadedScroll> {
  bool _more = false;

  bool _metrics(ScrollMetrics m) {
    final more = m.extentAfter > 0.5;
    if (more != _more) setState(() => _more = more);
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _metrics(n.metrics),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => _metrics(n.metrics),
          child: Stack(children: [
            widget.child,
            if (_more)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 40,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [widget.background.withValues(alpha: 0), widget.background]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// The re-ask card (SHARE_ASK_40 20.6): small, at the bottom of the window, at most 480 wide, no dim, no focus taken,
/// no timeout, announced politely once (a live region); its line and one row of two equal buttons. It has no yes:
/// "See how it helps" opens the full sheet, where consent is given.
class SharingCard extends StatelessWidget {
  const SharingCard({super.key, required this.deck, required this.tokens, required this.onOpen, required this.onNotNow});

  final SharingDeck deck;
  final SharingTokens tokens;
  final VoidCallback onOpen, onNotNow;

  /// The card's width at most, as on the other platforms.
  static const maxWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    final d = deck, t = tokens;
    return Directionality(
      textDirection: d.direction,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Semantics(
          container: true,
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.background,
              borderRadius: BorderRadius.circular(t.cardRadius),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8))],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                _Header(t),
                const SizedBox(height: 12),
                Text(d['card.line'], style: _style(d, 15.5, 24, FontWeight.w400, t.text, arabicLine: 27)),
                const SizedBox(height: 14),
                _Buttons(d, t,
                    primary: d['card.open'], secondary: d['card.not_now'], onPrimary: onOpen, onSecondary: onNotNow, row: true),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the settings read and do: the plugin's host, or a test's stand-in.
abstract interface class SharingSettingsActions {
  Future<SharingStateMessage> state();
  Future<void> setOn(bool on);

  /// True when the server took the deletion; false when nothing changed (no connection, a refusal).
  Future<bool> deleteShared();
}

/// The learner's switch, drawn in the accent.
class _Switch extends StatelessWidget {
  const _Switch({required this.value, required this.t, required this.onChanged, required this.label});
  final bool value;
  final SharingTokens t;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        label: label,
        child: _Tap(
          button: false,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          radius: 16,
          focusColor: t.text,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 52,
            height: 32,
            padding: const EdgeInsets.all(3),
            alignment: value ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            decoration: BoxDecoration(
              color: value ? t.accent : t.switchOff,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: value ? t.onAccent : const Color(0xFFFFFFFF), shape: BoxShape.circle),
            ),
          ),
        ),
      );
}

/// The settings: the learner's switch, "What is shared", "Delete what I shared" (with its confirmation) and the
/// recovery code, in the sheet's tokens.
class SharingSettings extends StatefulWidget {
  const SharingSettings({super.key, required this.deck, required this.tokens, required this.actions, required this.onClose});

  final SharingDeck deck;
  final SharingTokens tokens;
  final SharingSettingsActions actions;
  final VoidCallback onClose;

  @override
  State<SharingSettings> createState() => _SharingSettingsState();
}

class _SharingSettingsState extends State<SharingSettings> {
  SharingStateMessage? _state;
  bool _what = false, _code = false, _copied = false, _busy = false, _confirm = false, _failed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.actions.state();
      if (mounted) setState(() => _state = s);
    } catch (_) {
      // the client closed: the settings show what they had
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      await widget.actions.setOn(on);
    } catch (_) {
      // turning on while Quran Lab's switch has sharing off: the switch stays off
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _confirm = false;
      _message = null;
    });
    var ok = false;
    try {
      ok = await widget.actions.deleteShared();
    } catch (_) {
      ok = false;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
      _message = ok ? widget.deck['delete.done'] : widget.deck['delete.failed.network'];
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.deck, t = widget.tokens;
    final s = _state;
    final text = _style(d, 15.5, 24, FontWeight.w400, t.text, arabicLine: 27);
    final small = _style(d, 14.5, 22, FontWeight.w400, t.secondary, arabicLine: 25);
    final label = _style(d, 16, 20, FontWeight.w600, t.notNowLabel);
    Widget card(List<Widget> rows) => DecoratedBox(
          decoration: BoxDecoration(color: t.card, borderRadius: BorderRadius.circular(t.cardRadius)),
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
        );
    Widget disclosure(String key, bool open, VoidCallback onTap) => _Tap(
          onTap: onTap,
          focusColor: t.text,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              Expanded(child: Text(d[key], style: text)),
              _Mark(open ? SharingMark.chevronUp : SharingMark.chevronDown, t.secondary),
            ]),
          ),
        );
    Widget action(String text, VoidCallback? onTap, {bool filled = false}) => _Tap(
          onTap: onTap,
          radius: t.buttonRadius,
          focusColor: t.text,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: filled ? t.tint : null, borderRadius: BorderRadius.circular(t.buttonRadius)),
            child: Text(text, textAlign: TextAlign.center, style: label),
          ),
        );
    final code = s?.recoveryCode;
    return _Panel(
      t: t,
      d: d,
      onEscape: widget.onClose,
      shadow: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: _Header(t)),
            _Tap(
              onTap: widget.onClose,
              radius: 20,
              focusColor: t.text,
              label: 'Close',
              child: Padding(padding: const EdgeInsets.all(10), child: _Mark(SharingMark.close, t.secondary)),
            ),
          ]),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              card([
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    Expanded(child: ExcludeSemantics(child: Text(d['settings.toggle'], style: text))),
                    const SizedBox(width: 12),
                    _Switch(value: s?.on ?? false, t: t, label: d['settings.toggle'], onChanged: s == null || _busy ? null : _toggle),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              card([
                disclosure('settings.what', _what, () => setState(() => _what = !_what)),
                if (_what) Padding(padding: const EdgeInsets.only(bottom: 14), child: Text(d['what.detail'], style: small)),
              ]),
              if (code != null) ...[
                const SizedBox(height: 12),
                card([
                  disclosure('recovery.reveal', _code, () => setState(() => _code = !_code)),
                  // the code is drawn only when the learner opens it
                  if (_code) ...[
                    Text(code,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(inherit: false, fontFamily: 'monospace', fontSize: 18, height: 1.4, letterSpacing: 1, color: t.text)),
                    const SizedBox(height: 6),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: action(_copied ? d['recovery.copied'] : d['recovery.copy'], () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (mounted) setState(() => _copied = true);
                      }),
                    ),
                    Text(d['recovery.keep'], style: small),
                    const SizedBox(height: 8),
                    Text(d['recovery.hint'], style: small),
                    const SizedBox(height: 14),
                  ],
                ]),
              ],
              const SizedBox(height: 12),
              card([
                if (!_confirm)
                  _Tap(
                    onTap: _busy ? null : () => setState(() => _confirm = true),
                    focusColor: t.text,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Text(d['settings.delete'], style: label),
                    ),
                  )
                else ...[
                  // the confirmation: immediate, cannot be undone
                  Padding(padding: const EdgeInsets.only(top: 14, bottom: 10), child: Text(d['delete.confirm'], style: text)),
                  Row(children: [
                    Expanded(child: action(d['delete.cancel'], () => setState(() => _confirm = false))),
                    const SizedBox(width: 10),
                    Expanded(child: action(d['delete.action'], _delete, filled: true)),
                  ]),
                  const SizedBox(height: 12),
                ],
              ]),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_failed) Text(d['delete.failed.title'], style: _style(d, 15.5, 24, FontWeight.w600, t.text)),
                    Text(_message!, style: small),
                    if (_failed) action(d['delete.retry'], _busy ? null : _delete),
                  ]),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
