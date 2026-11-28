// Windows and Linux: the plugin's bindings against the C SDK's own library, with no key, no model and no request to
// Quran Lab. Skipped unless QURANLAB_C_SDK names the folder of the C SDK's libraries and the plugin's own (on Windows
// that folder must also be on PATH): the private CI's Windows job sets it to the release it bundles.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer/src/ffi/ffi_host.dart';
import 'package:quranlab_tajweedformer/src/ffi/native.dart';
import 'package:quranlab_tajweedformer/src/ffi/tajweedformer.g.dart';
import 'package:quranlab_tajweedformer/src/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['QURANLAB_C_SDK'];
  final skip = dir == null || !(Platform.isWindows || Platform.isLinux)
      ? 'set QURANLAB_C_SDK to the folder of the C SDK and the plugin\'s library (Windows, Linux)'
      : null;

  test('the library is the release the bindings were generated from', () {
    final n = TfNative.open(dir);
    expect(str(n.tf.tf_version()), TF_SDK_VERSION);
  }, skip: skip);

  test('every code of the C SDK is a code of the Dart catalogue, with its fix and docs', () {
    final n = TfNative.open(dir);
    final names = <String>[];
    for (final e in TfError.values) {
      if (e == TfError.TF_OK) continue;
      final name = str(n.tf.tf_error_name(e.value))!;
      names.add(name);
      expect(TajweedErrorCode.all, contains(name));
      expect(str(n.tf.tf_error_docs(e.value)), 'https://sdk.quranlab.ai/docs/errors#$name');
      expect(str(n.tf.tf_error_fix(e.value)), isNotEmpty);
    }
    expect(names.toSet(), TajweedErrorCode.all.toSet());
  }, skip: skip);

  test('a failure is the calling thread\'s, read at once with its message and fix', () {
    final n = TfNative.open(dir);
    expect(n.tf.tf_client_create(nullptr), nullptr);
    final e = n.lastError();
    expect(e.code, TajweedErrorCode.invalidArgument);
    expect(e.message, isNotEmpty);
    expect(e.cause, isNull);
  }, skip: skip);

  test('what the plugin keeps across a hot restart: one value per slot', () {
    final n = TfNative.open(dir);
    final before = n.setSlot(TfNative.slotSession, 0x1234);
    expect(n.slot(TfNative.slotSession), 0x1234);
    n.setSlot(TfNative.slotSession, before);
    expect(n.slot(99), 0);
  }, skip: skip);

  test('a string that is not a key is the SDK\'s invalid_argument, and no client is kept', () async {
    final host = FfiHost(libraryDir: dir);
    final err = await host
        .createClient('not a key', ClientOptionsMessage(appId: 'ai.quranlab.test.ffi', storage: Directory.systemTemp.path))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.invalidArgument));
    expect(TfNative.open(dir).slot(TfNative.slotClient), 0);
  }, skip: skip);

  test('pushed bytes become the samples the native SDKs take: float32, or 16-bit over 32768', () {
    final bytes = Int16List.fromList([0, 16384, -32768, 32767]).buffer.asUint8List();
    final p = samplesOf(bytes, true);
    expect(p.asTypedList(4), [0, 0.5, -1, 32767 / 32768]);
    calloc.free(p);
  });
}
