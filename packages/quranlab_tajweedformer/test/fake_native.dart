// A stand-in for the native side, at the level of the platform channels: it answers the host API's messages
// with the codec Pigeon generated and pushes updates through the event channel, exactly as Android or iOS would.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/messages.g.dart';

typedef Handler = FutureOr<Object?> Function(List<Object?> args);

class FakeNative {
  FakeNative() {
    messenger.setMockStreamHandler(
      const EventChannel('dev.flutter.pigeon.quranlab_tajweedformer.TajweedEventApi.updates', pigeonMethodCodec),
      MockStreamHandler.inline(onListen: (args, sink) => _sink = sink, onCancel: (args) => _sink = null),
    );
  }

  static const _prefix = 'dev.flutter.pigeon.quranlab_tajweedformer.TajweedHostApi.';
  final MessageCodec<Object?> codec = TajweedHostApi.pigeonChannelCodec;
  TestDefaultBinaryMessenger get messenger => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  MockStreamHandlerEventSink? _sink;

  /// Every call the Dart side made, in order: method name and arguments.
  final List<(String, List<Object?>)> calls = [];

  /// Answers [method] with [handler]'s result; a [PlatformException] it throws travels as the channel's error.
  void on(String method, Handler handler) {
    messenger.setMockMessageHandler(_prefix + method, (ByteData? message) async {
      final args = (codec.decodeMessage(message) as List<Object?>?) ?? const [];
      calls.add((method, args));
      try {
        return codec.encodeMessage(<Object?>[await handler(args)]);
      } on PlatformException catch (e) {
        return codec.encodeMessage(<Object?>[e.code, e.message, e.details]);
      }
    });
  }

  /// Answers every listed method with null (the void ones).
  void ok(List<String> methods) {
    for (final m in methods) {
      on(m, (_) => null);
    }
  }

  /// Sends an update to Dart, as the native side's event sink does.
  void emit(UpdateMessage u) => _sink!.success(u);

  bool get listening => _sink != null;

  void reset() {
    for (final m in [
      'createClient', 'closeClient', 'model', 'prefetch', 'storage', 'removeModels', 'diagnose', 'modelBackend',
      'closeModel', 'openSession', 'push', 'finish', 'cancel', 'sessionBackend', 'reportRecited',
      'referenceIsDownloaded', 'referenceFetch', 'referenceUnits', 'sharingState', 'sharingSetOn', 'sharingAsk',
      'sharingFeed', 'sharingItems', 'sharingSummary', 'sharingDelete', 'sharingSetWording', 'sharingSetTheme',
      'sharingOpenSettings', 'reportChecks',
    ]) {
      messenger.setMockMessageHandler(_prefix + m, null);
    }
  }
}

/// The SDK's error as the native side sends it: the code, the message, and [fix, docs, cause] (the cause or null).
PlatformException sdkError(String code, String message, String fix, {ErrorCauseMessage? cause}) =>
    PlatformException(code: code, message: message, details: [fix, 'https://sdk.quranlab.ai/docs/errors#$code', cause]);

/// A cause of `errors_40.json` (the report's names) as the native side sends it, or null.
ErrorCauseMessage? causeMessage(Map<String, Object?>? c) => c == null
    ? null
    : ErrorCauseMessage(
        stage: c['stage']! as String,
        reason: c['reason']! as String,
        httpStatus: c['http_status'] as int?,
        errorName: c['error_name'] as String?,
        errorCode: c['error_code'] as String?,
        needs: c['needs'] as String?,
      );

BackendMessage cpu() => BackendMessage(kind: 'cpu', name: 'cpu', stage: 'cpu');

/// A model of four tokens: blank, `a`, `b` and the word bar.
ModelMessage modelMessage({CalibrationMessage? calibration}) => ModelMessage(
      id: 'v4.0',
      version: '4.0.0',
      build: 'b6ae4d8b73d8b6ae4d8b73d8b6ae4d8b73d8b6ae',
      contexts: ['c16_l64', 'c8_l64'],
      chunkMs: [320, 160],
      defaultContext: 'c16_l64',
      tokens: TokensMessage(names: ['<blk>', 'a', 'b', '|'], blank: 0, wordBar: 3),
      calibration: calibration,
      hasReference: false,
      sampleClips: [ClipMessage(name: '001001', kind: 'clean', durationMs: 4200)],
      backend: cpu(),
    );

Uint8List f32(List<double> v) {
  final b = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    b.setFloat32(i * 4, v[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// A decoded delta: [ids] from [tokenStart], frames [frameStart, frameStart + frames).
DecodedMessage delta({
  int tokenStart = 0,
  List<int> ids = const [],
  int frameStart = 0,
  int frames = 0,
  int settled = 0,
  bool isFinal = false,
  int topFrom = 1,
}) {
  final n = ids.length;
  return DecodedMessage(
    tokenStart: tokenStart,
    tokenIds: Int32List.fromList(ids),
    tokenFirstMs: Int32List.fromList([for (var i = 0; i < n; i++) (tokenStart + i) * 80]),
    tokenPeakMs: Int32List.fromList([for (var i = 0; i < n; i++) (tokenStart + i) * 80 + 40]),
    tokenLastMs: Int32List.fromList([for (var i = 0; i < n; i++) (tokenStart + i) * 80 + 40]),
    tokenConfidence: Float64List.fromList([for (var i = 0; i < n; i++) i.isEven ? 0.9 : double.nan]),
    frameStart: frameStart,
    frameTop: Int32List.fromList([for (var i = 0; i < frames; i++) topFrom]),
    frameTopLogProb: Float64List.fromList([for (var i = 0; i < frames; i++) -0.1]),
    frameRunnerUp: Int32List.fromList([for (var i = 0; i < frames; i++) 0]),
    frameRunnerUpLogProb: Float64List.fromList([for (var i = 0; i < frames; i++) -2.6]),
    frameMargin: Float64List.fromList([for (var i = 0; i < frames; i++) 2.5]),
    topK: 0,
    frameTopK: Int32List(0),
    frameTopKLogProbs: Float64List(0),
    settled: settled,
    isFinal: isFinal,
  );
}

ChunkMessage chunkMessage(int index, DecodedMessage d, {List<HeadMessage> heads = const []}) => ChunkMessage(
      index: index,
      startMs: index * 320,
      endMs: (index + 1) * 320,
      firstFrame: index * 8,
      backend: cpu(),
      speech: true,
      heads: heads,
      decoded: d,
    );
