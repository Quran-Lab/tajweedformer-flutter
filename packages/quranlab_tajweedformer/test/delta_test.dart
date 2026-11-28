// The decoded layer's deltas of the hosts that run in Dart (Windows and Linux over the C SDK, the web over the hosted
// loader): the same rules as the native plugins' DeltaEncoder, so DecodedState rebuilds the take exactly.
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/bridge.dart';
import 'package:quranlab_tajweedformer/src/delta.dart';

void main() {
  // a take's decoded layer after n frames: one token per 3 frames, the last token still moving
  DecodedRows layer(int frames, {bool isFinal = false, int k = 0}) {
    final tokens = [
      for (var t = 0; t * 3 < frames; t++) TokenRow(1 + t % 5, t * 120, t * 120 + 40, t * 120 + 80, t.isEven ? 0.9 : double.nan),
    ];
    return DecodedRows(
      tokens: tokens,
      frameCount: frames,
      frame: (f) => (f % 7, -0.5 * f, (f + 1) % 7, -1.0 * f, 0.5 * f),
      rankedK: k,
      ranked: (f, j) => (j, -0.1 * j - f),
      settled: tokens.isEmpty ? 0 : tokens.length - 1,
      isFinal: isFinal,
    );
  }

  test('chunks send only what changed, and the Dart side rebuilds the whole layer', () {
    final enc = DeltaEncoder(2);
    final state = DecodedState(const ['<b>', 'a', 'b', 'c', 'd', 'e'], null);
    var frames = 0;
    for (var chunk = 0; chunk < 6; chunk++) {
      final first = frames;
      frames += 8;
      final m = enc.chunk(layer(frames, k: 2, isFinal: chunk == 5), first);
      expect(m.frameStart, first, reason: 'the frames from the chunk\'s own first frame');
      expect(m.frameTop.length, 8);
      final d = state.apply(m);
      final whole = layer(frames, k: 2);
      expect(d.frames.length, frames);
      expect([for (final f in d.frames) f.top], [for (var f = 0; f < frames; f++) f % 7]);
      expect(d.frames.last.topK, [0, 1]);
      expect([for (final t in d.tokens) t.id], [for (final t in whole.tokens) t.id]);
      expect(d.tokens.where((t) => t.confidence == null).length, whole.tokens.where((t) => t.confidence.isNaN).length);
      expect(d.isFinal, chunk == 5);
    }
  });

  test('a token that changes is sent again from there; an unchanged prefix is not', () {
    final enc = DeltaEncoder(0);
    final a = [const TokenRow(1, 0, 40, 80, 0.5), const TokenRow(2, 120, 160, 200, 0.5)];
    final b = [const TokenRow(1, 0, 40, 80, 0.5), const TokenRow(3, 120, 160, 240, 0.5), const TokenRow(4, 280, 320, 320, 0.5)];
    DecodedRows rows(List<TokenRow> t, int n) =>
        DecodedRows(tokens: t, frameCount: n, frame: (f) => (0, 0, 0, 0, 0), settled: 1, isFinal: false);
    expect(enc.chunk(rows(a, 8), 0).tokenStart, 0);
    final m = enc.chunk(rows(b, 16), 8);
    expect(m.tokenStart, 1);
    expect(m.tokenIds, [3, 4]);
    expect(m.topK, 0);
    expect(m.frameTopK, isEmpty);
  });

  test('a replay (the frames from an earlier chunk again) starts where the replay starts', () {
    final enc = DeltaEncoder(0);
    enc.chunk(layer(16), 0);
    enc.chunk(layer(24), 16);
    final m = enc.chunk(layer(24), 8);
    expect(m.frameStart, 8);
    expect(m.frameTop.length, 16);
  });

  test('the whole layer starts at 0', () {
    final m = DeltaEncoder(3).whole(layer(10, k: 3, isFinal: true));
    expect(m.tokenStart, 0);
    expect(m.frameStart, 0);
    expect(m.frameTop.length, 10);
    expect(m.frameTopK.length, 30);
    expect(m.isFinal, isTrue);
  });
}
