// A take's decoded layer as deltas, for the hosts that run in Dart (the C SDK's on Windows and Linux, the hosted
// loader's on the web): the same rules as Wire.kt's and Wire.swift's DeltaEncoder, so DecodedState (bridge.dart)
// rebuilds every platform's layer the same way. Internal.
import 'dart:math' as math;
import 'dart:typed_data';

import 'messages.g.dart';

/// One token as the encoder compares it: the same token in the same place is not sent again.
final class TokenRow {
  const TokenRow(this.id, this.firstMs, this.peakMs, this.lastMs, this.confidence);

  final int id;
  final int firstMs;
  final int peakMs;
  final int lastMs;

  /// NaN where the SDK has none.
  final double confidence;

  @override
  bool operator ==(Object other) =>
      other is TokenRow &&
      other.id == id &&
      other.firstMs == firstMs &&
      other.peakMs == peakMs &&
      other.lastMs == lastMs &&
      (other.confidence == confidence || (other.confidence.isNaN && confidence.isNaN));

  @override
  int get hashCode => Object.hash(id, firstMs, peakMs, lastMs);
}

/// A decoded layer as the platform's SDK holds it: its tokens, and its frames read one at a time (a take's frames
/// are only read from where the app's copy stops).
final class DecodedRows {
  DecodedRows({
    required this.tokens,
    required this.frameCount,
    required this.frame,
    required this.settled,
    required this.isFinal,
    this.rankedK = 0,
    this.ranked,
  });

  final List<TokenRow> tokens;
  final int frameCount;

  /// The frame's top token, its log-probability, the runner-up, its log-probability and the margin.
  final (int, double, int, double, double) Function(int frame) frame;

  /// How many ranked tokens each frame has (0: none), and the k-th of a frame: its id and log-probability.
  final int rankedK;
  final (int, double) Function(int frame, int k)? ranked;
  final int settled;
  final bool isFinal;
}

/// One take's encoder: the tokens from the first one that differs from what Dart holds, the frames from the chunk's
/// own first frame (a replay sends them again).
class DeltaEncoder {
  DeltaEncoder(this.topK);

  /// The K the session asked for: every message carries K ranked tokens per frame (-1 and -infinity where the SDK
  /// ranked fewer).
  final int topK;
  List<TokenRow> _sentTokens = const [];
  int _sentFrames = 0;

  DecodedMessage chunk(DecodedRows d, int firstFrame) {
    var t = 0;
    final same = math.min(d.tokens.length, _sentTokens.length);
    while (t < same && d.tokens[t] == _sentTokens[t]) {
      t++;
    }
    final f = math.min(math.min(_sentFrames, math.max(0, firstFrame)), d.frameCount);
    final m = encode(d, t, f);
    _sentTokens = d.tokens;
    _sentFrames = d.frameCount;
    return m;
  }

  /// A whole decoded layer (the one `finish` returns).
  DecodedMessage whole(DecodedRows d) => encode(d, 0, 0);

  DecodedMessage encode(DecodedRows d, int tokenStart, int frameStart) {
    final t = tokenStart < d.tokens.length ? d.tokens.sublist(tokenStart) : const <TokenRow>[];
    final n = math.max(0, d.frameCount - frameStart);
    final top = Int32List(n), runnerUp = Int32List(n);
    final topLp = Float64List(n), runnerUpLp = Float64List(n), margin = Float64List(n);
    final tk = Int32List(n * topK)..fillRange(0, n * topK, -1);
    final tkl = Float64List(n * topK)..fillRange(0, n * topK, double.negativeInfinity);
    for (var i = 0; i < n; i++) {
      final (a, b, c, e, g) = d.frame(frameStart + i);
      top[i] = a;
      topLp[i] = b;
      runnerUp[i] = c;
      runnerUpLp[i] = e;
      margin[i] = g;
      final ranked = d.ranked;
      if (ranked != null) {
        for (var k = 0; k < topK && k < d.rankedK; k++) {
          final (id, lp) = ranked(frameStart + i, k);
          tk[i * topK + k] = id;
          tkl[i * topK + k] = lp;
        }
      }
    }
    return DecodedMessage(
      tokenStart: tokenStart,
      tokenIds: Int32List.fromList([for (final x in t) x.id]),
      tokenFirstMs: Int32List.fromList([for (final x in t) x.firstMs]),
      tokenPeakMs: Int32List.fromList([for (final x in t) x.peakMs]),
      tokenLastMs: Int32List.fromList([for (final x in t) x.lastMs]),
      tokenConfidence: Float64List.fromList([for (final x in t) x.confidence]),
      frameStart: frameStart,
      frameTop: top,
      frameTopLogProb: topLp,
      frameRunnerUp: runnerUp,
      frameRunnerUpLogProb: runnerUpLp,
      frameMargin: margin,
      topK: topK,
      frameTopK: tk,
      frameTopKLogProbs: tkl,
      settled: d.settled,
      isFinal: d.isFinal,
    );
  }
}
