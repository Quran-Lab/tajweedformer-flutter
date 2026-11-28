// Windows and Linux: the C SDK has no UI ("the ask is the app's to draw"), so the plugin draws the SDK's sharing sheet,
// its re-ask card and its settings (sharing_sheet.dart), with the C SDK's copy deck, in the app's root Overlay, and
// tells the C SDK what the learner did, only from the learner's own taps. The SDK's rules decide when an ask comes;
// nothing here asks by itself. An app with no Overlay (no Navigator) has nowhere to show the ask: it is withdrawn, as
// the Apple SDK does without a window, and never counted. Internal.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../messages.g.dart';
import 'ffi_host.dart';
import 'sharing_sheet.dart';

class SharingUi implements SharingSettingsActions {
  SharingUi(this.host);

  final FfiHost host;
  OverlayEntry? _sheet, _card, _settings;

  /// The app's root Overlay (its Navigator's), found from the root of the widget tree.
  static OverlayState? overlay() {
    OverlayState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is OverlayState) {
        found = e.state as OverlayState;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  SharingDeck _deck() => SharingDeck(host.copyDeck());

  Widget _tokens(SharingThemeMessage theme, Widget Function(SharingTokens t) child) => Builder(
      builder: (context) => child(SharingTokens.of(theme, MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light,
          highContrast: MediaQuery.maybeHighContrastOf(context) ?? false)));

  /// Shows the ask in hand (the sheet, or with [card] the card) and returns whether it is on screen (the SDK counted
  /// it).
  Future<bool> presentAsk(bool card, SharingThemeMessage theme) async {
    if (_sheet != null || _card != null) return true;
    final o = overlay();
    if (o == null) return false;
    final deck = _deck();
    final entry = card ? _cardEntry(deck, theme) : _sheetEntry(deck, theme);
    card ? _card = entry : _sheet = entry;
    o.insert(entry);
    final shown = Completer<bool>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // on screen now: the ask counts; 0 is the SDK taking it back (a take started, another process answered), and
      // a client closed meanwhile shows nothing
      final ok = host.shownSafely();
      if (!ok) _remove(card);
      shown.complete(ok);
    });
    WidgetsBinding.instance.scheduleFrame();
    return shown.future;
  }

  void _remove(bool card) {
    final e = card ? _card : _sheet;
    if (card) {
      _card = null;
    } else {
      _sheet = null;
    }
    e?.remove();
  }

  /// The sheet as it sits over the app's window: modal, dimmed behind, centred, at most 480 wide and 92 % of the
  /// window's height. Also what the review pictures draw (example/tool/sharing_screens_test.dart).
  static Widget sheetLayout(BuildContext context, SharingDeck deck, SharingTokens t,
          {required VoidCallback onShare, required VoidCallback onNotNow}) =>
      Stack(children: [
        // the sheet is modal: the app waits behind it until the learner taps one of its two buttons
        const ModalBarrier(color: Color(0x66000000), dismissible: false),
        SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 480, maxHeight: MediaQuery.sizeOf(context).height * 0.92),
                child: SharingSheet(deck: deck, tokens: t, onShare: onShare, onNotNow: onNotNow),
              ),
            ),
          ),
        ),
      ]);

  /// The card as it sits over the app's window: no dim, at the bottom, 16 above the window's edge, at most 480 wide
  /// (SharingCard). Also what the review pictures draw.
  static Widget cardLayout(SharingDeck deck, SharingTokens t, {required VoidCallback onOpen, required VoidCallback onNotNow}) =>
      SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SharingCard(deck: deck, tokens: t, onOpen: onOpen, onNotNow: onNotNow),
          ),
        ),
      );

  OverlayEntry _sheetEntry(SharingDeck deck, SharingThemeMessage theme) => OverlayEntry(
        builder: (context) => _tokens(
          theme,
          (t) => sheetLayout(
            context,
            deck,
            t,
            onShare: () {
              _remove(false);
              host.answer(true);
            },
            onNotNow: () {
              _remove(false);
              host.answer(false);
            },
          ),
        ),
      );

  OverlayEntry _cardEntry(SharingDeck deck, SharingThemeMessage theme) => OverlayEntry(
        builder: (context) => _tokens(
          theme,
          (t) => cardLayout(
            deck,
            t,
            onOpen: () {
              _remove(true);
              // the full sheet for the same ask, where consent is given
              if (host.openCard()) unawaited(presentAsk(false, theme));
            },
            onNotNow: () {
              _remove(true);
              host.answer(false);
            },
          ),
        ),
      );

  /// Shows the settings; false when the app has no Overlay to show them on.
  Future<bool> openSettings(SharingThemeMessage theme) async {
    final o = overlay();
    if (o == null) return false;
    _settings?.remove();
    final deck = _deck();
    final entry = OverlayEntry(
      builder: (context) => _tokens(
        theme,
        (t) => Stack(children: [
          ModalBarrier(color: const Color(0x66000000), dismissible: true, onDismiss: _closeSettings),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 480, maxHeight: MediaQuery.sizeOf(context).height * 0.92),
                  child: SharingSettings(deck: deck, tokens: t, actions: this, onClose: _closeSettings),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
    _settings = entry;
    o.insert(entry);
    return true;
  }

  void _closeSettings() {
    _settings?.remove();
    _settings = null;
  }

  @override
  Future<SharingStateMessage> state() => host.sharingState();

  @override
  Future<void> setOn(bool on) => host.sharingSetOn(on);

  @override
  Future<bool> deleteShared() => host.sharingDelete();

  /// The card leaves the screen with no answer of ours (a take starts, sharing is turned off or deleted): the SDK
  /// counts a card on screen as "Not now" by its own rules.
  void withdrawCard() {
    if (_card == null) return;
    _remove(true);
  }

  /// The sheet and the card leave the screen with no answer of ours: the app left the foreground, and the SDK took
  /// the ask back (tf_client_background). A learner's tap can then never record a consent the SDK no longer holds.
  void withdrawAsk() {
    _remove(true);
    _remove(false);
  }

  /// Everything leaves the screen (the client closes).
  void dismiss() {
    _remove(true);
    _remove(false);
    _closeSettings();
  }
}
