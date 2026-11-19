/// An optional microphone for `quranlab_tajweedformer`: the `record` package captures 16 kHz mono 16-bit PCM and
/// this pushes it into a TajweedFormer take.
///
/// Most apps do not need it: `model.listen()` uses the SDK's own microphone (interruptions, route changes and the
/// end of a take in the background included). Use this when your app already captures audio with `record`, or
/// wants to keep the recording itself.
///
/// ```dart
/// final mic = TajweedRecorder();
/// final session = await mic.start(model);
/// session.chunks.listen((c) => print(c.decoded.text));
/// // ...
/// final heads = await mic.stop();
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:record/record.dart';

class TajweedRecorder {
  TajweedRecorder({AudioRecorder? recorder}) : _recorder = recorder ?? AudioRecorder();

  /// What is captured: 16-bit PCM, 16 kHz, mono (the model's own rate, so nothing is resampled).
  static const config = RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1);

  final AudioRecorder _recorder;
  TajweedSession? _session;
  Future<void>? _pump;

  /// Asks for the microphone (a refusal is `microphone_denied`), opens a take on [model] that the captured audio
  /// is pushed into, and starts capturing. [options] apply except its sample rate, which is the capture's.
  Future<TajweedSession> start(TajweedModel model, {TajweedSessionOptions options = const TajweedSessionOptions()}) async {
    if (_session != null) {
      throw const TajweedError(TajweedErrorCode.sessionOpen, 'This recorder already feeds a take.',
          fix: 'Stop or cancel the take before starting another.');
    }
    if (!await _recorder.hasPermission()) {
      throw const TajweedError(TajweedErrorCode.microphoneDenied, 'The microphone permission was refused.',
          fix: 'Ask the learner to allow the microphone in the system settings, then start again.');
    }
    final session = await model.session(
        options: TajweedSessionOptions(
      context: options.context,
      sampleRate: config.sampleRate,
      heads: options.heads,
      backend: options.backend,
      topK: options.topK,
      endOnSilenceMs: options.endOnSilenceMs,
      pace: options.pace,
    ));
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(config);
    } catch (e) {
      await session.cancel();
      throw TajweedError(TajweedErrorCode.microphoneUnavailable, 'The microphone could not be opened: $e',
          fix: 'Check that no other app holds the microphone, then start again.');
    }
    _session = session;
    _pump = pumpPcm16(stream, session.pushInt16).whenComplete(() async {
      // the take ended by itself (silence, the 20 minute limit): stop capturing
      if (await _recorder.isRecording()) await _recorder.stop();
    });
    return session;
  }

  /// Stops capturing, lets the last samples in, and finishes the take: its heads.
  Future<TajweedHeads> stop() async {
    final session = _session;
    if (session == null) {
      throw const TajweedError(TajweedErrorCode.sessionClosed, 'This recorder feeds no take.',
          fix: 'Start a take with start() first.');
    }
    await _recorder.stop();
    await _pump;
    _session = null;
    _pump = null;
    return session.finish();
  }

  /// Stops capturing and cancels the take.
  Future<void> cancel() async {
    final session = _session;
    _session = null;
    await _recorder.cancel();
    await _pump;
    _pump = null;
    await session?.cancel();
  }

  /// Releases the recorder.
  Future<void> dispose() async {
    if (_session != null) await cancel();
    await _recorder.dispose();
  }
}

/// Pushes 16-bit little-endian PCM bytes into a take as they come, in order. A piece with an odd byte count
/// keeps its last byte for the next one. Ends when [bytes] ends, or when the take does (a push after its end).
Future<void> pumpPcm16(Stream<Uint8List> bytes, Future<void> Function(Int16List samples) push) async {
  int? carry;
  await for (final piece in bytes) {
    if (piece.isEmpty) continue;
    final b = carry == null ? piece : (Uint8List(piece.length + 1)..[0] = carry..setRange(1, piece.length + 1, piece));
    final even = b.length & ~1;
    carry = b.length.isOdd ? b[b.length - 1] : null;
    if (even == 0) continue;
    final data = ByteData.sublistView(b, 0, even);
    final samples = Int16List(even ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }
    try {
      await push(samples);
    } on TajweedError catch (e) {
      if (e.code == TajweedErrorCode.sessionClosed) return;
      rethrow;
    }
  }
}
