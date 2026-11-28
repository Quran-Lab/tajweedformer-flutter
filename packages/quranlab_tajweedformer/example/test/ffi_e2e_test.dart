// The Windows and Linux path without a device: `flutter test` on the host machine runs the plugin's C SDK host
// (lib/src/ffi) over the C SDK's own libraries, against Quran Lab's servers, with the same 35-clip check as every
// platform (lib/e2e/conformance.dart). It is skipped unless its inputs are named (CI names none: the CI machine never
// holds a model). The key is read from its file and never printed.
//
//   QURANLAB_C_SDK          the folder with tajweedformer.dll, qlcore.dll, libwinpthread-1.dll and
//                           quranlab_tajweedformer_shim.dll (Windows; on Windows it must also be on PATH, for the
//                           libraries the SDK loads), or libtajweedformer.so, qlcore.so and
//                           libquranlab_tajweedformer_shim.so (Linux)
//   QURANLAB_E2E_DIR        a folder for the SDK's storage and result.jsonl
//   QURANLAB_E2E_KEY_FILE   the desktop key's file
//   QURANLAB_E2E_APP_ID     the app id the key is registered for
//   QURANLAB_E2E_EXPECTED   the Core gate's expected.jsonl
//   QURANLAB_E2E_CLIPS      the folder of its clips (<clip>.pcm)
//
//   flutter test test/ffi_e2e_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/bridge.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/ffi/ffi_host.dart';
// ignore: implementation_imports
import 'package:quranlab_tajweedformer/src/messages.g.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer_example/e2e/conformance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final lib = env['QURANLAB_C_SDK'], dir = env['QURANLAB_E2E_DIR'], keyFile = env['QURANLAB_E2E_KEY_FILE'];

  void report(String step, Map<String, Object?> data) {
    final line = jsonEncode({'step': step, 'platform': Platform.operatingSystem, ...data});
    // ignore: avoid_print
    print('E2E $line');
    File('$dir/result.jsonl').writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  test('the C SDK through the plugin: register, lease, download, open, the 35 clips, a pushed take, the errors',
      () async {
    if (lib == null || dir == null || keyFile == null || !(Platform.isWindows || Platform.isLinux)) {
      markTestSkipped('set QURANLAB_C_SDK, QURANLAB_E2E_DIR and the inputs (see the top of this file)');
      return;
    }
    Bridge.instance.debugHost = FfiHost(libraryDir: lib);
    final key = File(keyFile).readAsStringSync().trim();

    final t0 = DateTime.now();
    final client = await TajweedClient.create(key,
        options: TajweedClientOptions(appId: env['QURANLAB_E2E_APP_ID'], appVersion: '4.1.0', storage: '$dir/storage'));
    // the same key again is the same client; another key is client_exists
    expect(identical(await TajweedClient.create(key), client), isTrue);
    var done = 0, total = 0;
    final model = await client.model(onProgress: (d, t) {
      done = d;
      total = t;
    });
    final open = await openReport(client, model, DateTime.now().difference(t0).inMilliseconds, done, total);
    report('open', open);
    final d = await client.diagnose();
    expect(d.keyAccepted, isTrue);
    expect(d.modelVerified, isTrue);
    expect(d.protectedModel?.lease, 'valid');

    // ---- the 35 clips ----
    final expected = expectedOf(File(env['QURANLAB_E2E_EXPECTED']!).readAsStringSync());
    final r = await conformance(model, expected, (clip) async {
      final raw = File('${env['QURANLAB_E2E_CLIPS']}/$clip.pcm').readAsBytesSync();
      return raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
    });
    report('conformance', r);
    expect(expected, hasLength(35));
    expect(r['tokens_same'], 35);
    expect(r['identical'], 35);
    expect(r['digest'], r['gate_digest']);

    // ---- a sample clip through tf_session_listen, at the clip's pace ----
    final clip = model.sampleClips.first;
    final s1 = await model.listenFrom(clip, options: const TajweedSessionOptions(pace: TajweedPace.fast));
    final events = <TajweedEvent>[];
    final eventsDone = s1.events.forEach(events.add);
    final chunks1 = await s1.chunks.toList();
    await eventsDone;
    final h1 = await s1.finish();
    report('clip', {
      'clip': '$clip',
      'chunks': chunks1.length,
      'final': chunks1.isNotEmpty && chunks1.last.decoded.isFinal,
      'tokens': h1.decoded().tokens.length,
      'events': [for (final e in events) e.runtimeType.toString()],
      'ended': events.whereType<TajweedEnded>().map((e) => e.reason.name).toList(),
    });
    expect(events.last, isA<TajweedEnded>().having((e) => e.reason, 'reason', TajweedEndReason.sourceEnd));
    expect(h1.decoded().text, chunks1.last.decoded.text);

    // ---- a pushed take: 16-bit samples in pieces, the same tokens as the clip's float run ----
    final e0 = expected.first;
    final raw = File('${env['QURANLAB_E2E_CLIPS']}/${e0['clip']}.pcm').readAsBytesSync();
    final f = raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
    final s2 = await model.session(options: const TajweedSessionOptions(topK: 3));
    final got = <TajweedChunk>[];
    final chunksDone = s2.chunks.forEach(got.add);
    for (var at = 0; at < f.length; at += 1234) {
      await s2.push(Float32List.sublistView(f, at, at + 1234 < f.length ? at + 1234 : f.length));
    }
    final h2 = await s2.finish();
    await chunksDone;
    report('push', {
      'chunks': got.length,
      'tokens': [for (final t in h2.greedy()) t.id],
      'gate_tokens': e0['tokens'],
      'topK': got.isEmpty || got.last.decoded.frames.isEmpty ? 0 : got.last.decoded.frames.last.topK.length,
      'backend': '${await s2.backend()}',
    });
    expect([for (final t in h2.greedy()) t.id], e0['tokens']);
    expect(got.last.decoded.frames.last.topK, hasLength(3));

    // ---- cancel, and finish after it ----
    final s3 = await model.session();
    await s3.push(Float32List.sublistView(f, 0, 16000));
    await s3.cancel();
    final afterCancel = await s3.finish().then((_) => 'none', onError: (Object e) => e is TajweedError ? e.code : '$e');
    report('cancel', {'finish_after_cancel': afterCancel});
    expect(afterCancel, TajweedErrorCode.cancelled);

    // ---- the gaps of Windows and Linux are the catalogue's errors ----
    final listen = await model.listen().then((s) async {
      await s.cancel();
      return 'none';
    }, onError: (Object e) => e is TajweedError ? e.code : '$e');
    report('listen', {'code': listen});
    expect(listen, TajweedErrorCode.runtimeUnsupported);

    // ---- the reference data, sharing, storage ----
    final ref = model.reference;
    Map<String, Object?> refReport = {'present': ref != null};
    if (ref != null) {
      await ref.fetch();
      final u = await ref.units(1, 1);
      refReport = {...refReport, 'downloaded': await ref.isDownloaded(), 'units': u.units.length, 'words': u.wordStarts};
    }
    report('reference', refReport);
    final sharing = {
      'available': await client.sharing.isAvailable(),
      'on': await client.sharing.isOn(),
      'items': (await client.sharing.items()).length,
      'ask': await client.sharing.ask(),
    };
    report('sharing', sharing);
    final storage = await client.storage();
    report('storage', {'models': storage.models.length, 'queue': storage.sharingQueueBytes});

    // ---- what a hot restart finds: a second host in the same process, the same key, the same client and model ----
    final again = FfiHost(libraryDir: lib);
    final other = await again
        .createClient('qlk_v1_another_key_for_this_check', ClientOptionsMessage(appId: env['QURANLAB_E2E_APP_ID']))
        .then((_) => 'none', onError: (Object e) => e is TajweedError ? e.code : '$e');
    await again.createClient(key, ClientOptionsMessage(appId: env['QURANLAB_E2E_APP_ID'], storage: '$dir/storage'));
    final m2 = await again.model(null, null);
    await again.openSession(
        900001, 'push', SessionOptionsMessage(sampleRate: 16000, backend: 'auto', topK: 0, pace: 'realTime'), null, null, null);
    await again.push(900001, Uint8List.sublistView(raw), false);
    final h3 = await again.finish(900001);
    report('second_host', {
      'another_key': other,
      'same_model': m2.build == model.build,
      'tokens_same': h3.decoded.tokenIds.toList().toString() == '${e0['tokens']}',
    });
    expect(other, TajweedErrorCode.clientExists);
    expect(m2.build, model.build);
    // as after a real hot restart, the new Dart's host closes the model and the client, and the first host is left as
    // a dead isolate's would be: its engine isolate is still alive here, so it must not touch the session the second
    // host took over (a hot restart's new engine cancels and frees the take the old one left in the plugin's slot)
    await again.closeModel();
    await again.closeClient();
    report('done', {});
  }, timeout: const Timeout(Duration(minutes: 30)));
}
