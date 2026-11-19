import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer_record/quranlab_tajweedformer_record.dart';

Uint8List le(List<int> samples) {
  final b = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(i * 2, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('pieces with odd byte counts keep their order and their samples', () async {
    final all = le([1, -2, 300, -32768, 32767, 7]);
    // 3 + 4 + 5 bytes: every split falls inside a sample at least once
    final pieces = [all.sublist(0, 3), all.sublist(3, 7), all.sublist(7, 12)];
    final got = <int>[];
    await pumpPcm16(Stream.fromIterable(pieces), (s) async => got.addAll(s));
    expect(got, [1, -2, 300, -32768, 32767, 7]);
  });

  test('a take that ended stops the pump without an error', () async {
    var pushes = 0;
    await pumpPcm16(Stream.fromIterable([le([1]), le([2]), le([3])]), (s) async {
      pushes++;
      if (pushes == 2) {
        throw const TajweedError(TajweedErrorCode.sessionClosed, 'over');
      }
    });
    expect(pushes, 2);
  });

  test('another failure reaches the caller', () async {
    await expectLater(
        pumpPcm16(Stream.fromIterable([le([1])]), (s) async => throw const TajweedError(TajweedErrorCode.engineFailed, 'x')),
        throwsA(isA<TajweedError>()));
  });

  test('the capture is the model\'s own rate, mono, 16-bit', () {
    expect(TajweedRecorder.config.sampleRate, 16000);
    expect(TajweedRecorder.config.numChannels, 1);
  });
}
