// SDK 4.0 end to end through the plugin, on an Android device or emulator, the iOS Simulator or an iPhone against
// Quran Lab's servers (not run by CI: the CI machine has no device and never holds a model). Nothing secret is in the
// app: the inputs go into the app's own folder first (Android: adb push, then `run-as <app id> cp` into files/; the
// iOS Simulator: Documents/ of the container `xcrun simctl get_app_container <device> <bundle id> data` gives; an
// iPhone: `xcrun devicectl device copy to --domain-type appDataContainer` into Documents/), and the key is never
// printed. Below, files/ stands for that folder.
//
//   files/e2e/key                the key (on the emulator or the Simulator, a development key: those Core builds are
//                                leased to development keys only)
//   files/e2e/expected.jsonl     the Core gate's file: per clip its greedy tokens and the FNV-1a of every head of
//                                every chunk
//   files/e2e/clips/<clip>.pcm   its clips, 16 kHz mono float32 little endian
//   files/e2e/deny_microphone    present: the error step with the microphone (the host denied it for good: Android
//                                `pm set-permission-flags ... user-fixed`, the Simulator `simctl privacy ... revoke
//                                microphone`; listen() is microphone_denied, which the native SDK reports)
//   files/e2e/break_storage      present: the error step with the SDK's storage instead (a device that cannot be
//                                denied the microphone without a person): the models folder is set aside and a file
//                                put in its place, prefetch() is storage_failed, which the native SDK reports, and the
//                                folder is put back
//   files/e2e/accelerator        present: the accelerator step: a take on `auto`, then the promotion waited for (its
//                                text: the seconds to wait, 300 by default), then a take on what was promoted
//
// Run: build it as the app (`flutter build apk --debug -t integration_test/e2e_test.dart` with QURANLAB_APPLICATION_ID
// set to the key's app id; iOS: `flutter build ios --simulator --debug -t ...`, or a signed profile build for an
// iPhone, with the key's bundle id), install it, put the inputs in place, start it and read its log (`flutter test` on
// a device uninstalls the app at the end). Each step prints one line `E2E <json>` and appends it to
// files/e2e/result.jsonl.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

/// The app's own files folder without a plugin: on Android from the process name (the app id), on iOS the app
/// container's Documents (the container is the parent of the app's tmp).
Directory filesDir() {
  if (Platform.isIOS) return Directory('${Directory.systemTemp.parent.path}/Documents');
  final name = File('/proc/self/cmdline').readAsStringSync().split('\u0000').first.split(':').first;
  return Directory('/data/user/0/$name/files');
}

void report(String step, Map<String, Object?> data) {
  final line = jsonEncode({'step': step, ...data});
  // ignore: avoid_print
  print('E2E $line');
  try {
    File('${filesDir().path}/e2e/result.jsonl').writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// The native SDK's own folder (its models live in `models/` there).
Directory sdkDir() => Platform.isIOS
    ? Directory('${Directory.systemTemp.parent.path}/Library/Application Support/QuranLab')
    : Directory('${filesDir().parent.path}/no_backup/quranlab');

/// FNV-1a 64 over bytes. The Core's conformance tools (qlc_bench.c, zf_test.h) start it at 1469598103934665603, the
/// standard basis with its last digit dropped, and the gate file's per-chunk values and `logp_fnv` were made with it;
/// the one digest over the 35 clips below uses the standard basis, as stage B's device test did.
const _gateBasis = 1469598103934665603;
const _fnvOffset = 0xcbf29ce484222325;
const _fnvPrime = 0x100000001b3;

int fnv(int h, Uint8List bytes) {
  var x = h;
  for (final b in bytes) {
    x = (x ^ b) * _fnvPrime;
  }
  return x;
}

/// The 64 bits as 16 hex digits (a Dart int is signed: the high and low halves are written apart).
String hex(int x) =>
    (x >>> 32).toRadixString(16).padLeft(8, '0') + (x & 0xffffffff).toRadixString(16).padLeft(8, '0');

Uint8List bytesOf(Float32List v) => v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('SDK 4.0: register, lease, download, open, the 35 clips, an error report', () async {
    // No widget is drawn here. A live app's platform can switch semantics on during the run (an accessibility client
    // on the machine), and the test framework's end-of-test check then takes the handle it opens for one the test left
    // open: the platform's switch is not followed while this test runs.
    WidgetsBinding.instance.platformDispatcher.onSemanticsEnabledChanged = () {};
    final dir = Directory('${filesDir().path}/e2e');
    final keyFile = File('${dir.path}/key');
    if (!keyFile.existsSync()) {
      markTestSkipped('no key in ${dir.path}');
      return;
    }
    final key = keyFile.readAsStringSync().trim();

    // ---- register, the lease, the download, the open ----
    final t0 = DateTime.now();
    final client = await TajweedClient.create(key);
    var done = 0;
    var total = 0;
    final model = await client.model(onProgress: (d, t) {
      done = d;
      total = t;
    });
    final openMs = DateTime.now().difference(t0).inMilliseconds;
    final d = await client.diagnose();
    final storage = await client.storage();
    report('open', {
      'ms': openMs,
      'download_done': done,
      'download_total': total,
      'model': model.version,
      'build': model.build,
      'contexts': model.contexts,
      'backend': '${await model.backend()}',
      'sdk': d.sdkVersion,
      'key_accepted': d.keyAccepted,
      'key_reason': d.keyReason,
      'config': d.config,
      'model_verified': d.modelVerified,
      'connection': d.connection,
      'protected': {
        'keyStore': d.protectedModel?.keyStore,
        'lease': d.protectedModel?.lease,
        'leaseClass': d.protectedModel?.leaseClass,
        'leaseExpires': d.protectedModel?.leaseExpires,
        'refreshAfter': d.protectedModel?.refreshAfter,
        'graceUntil': d.protectedModel?.graceUntil,
        'core': d.protectedModel?.core,
      },
      'stored': [for (final m in storage.models) '${m.version} ${m.build} ${m.bytes}'],
    });
    expect(d.keyAccepted, isTrue);
    expect(d.modelVerified, isTrue);
    expect(d.protectedModel?.lease, 'valid');

    // ---- the 35 clips on the CPU engine, every head of every chunk against the gate's FNV-1a ----
    final heads12 = [...TajweedSessionOptions.allHeads]..sort();
    final expected = [
      for (final line in File('${dir.path}/expected.jsonl').readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
    var identical = 0;
    var tokensSame = 0;
    var chunksAll = 0;
    var digest = _fnvOffset;
    var gateDigest = _fnvOffset;
    final bad = <String>[];
    final clipsStart = DateTime.now();
    for (final e in expected) {
      final clip = e['clip'] as String;
      final raw = File('${dir.path}/clips/$clip.pcm').readAsBytesSync();
      final samples = raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
      final session = await model.listenFromSamples(samples, 16000,
          options: const TajweedSessionOptions(
              context: 'c16_l64',
              heads: TajweedSessionOptions.allHeads,
              backend: TajweedSessionBackend.cpu,
              pace: TajweedPace.fast));
      final chunks = await session.chunks.toList();
      final heads = await session.finish();
      chunksAll += chunks.length;
      final want = [for (final t in e['tokens'] as List) (t as num).toInt()];
      final got = [for (final t in heads.greedy()) t.id];
      if (got.length == want.length && Iterable<int>.generate(got.length).every((i) => got[i] == want[i])) tokensSame++;
      final out = (e['out_fnv'] as Map).cast<String, List<Object?>>();
      final fnvs = <String, List<String>>{};
      var logp = _gateBasis;
      for (final c in chunks) {
        for (final h in heads12) {
          final v = c.heads[h]?.values;
          (fnvs[h] ??= []).add(v == null ? '0000000000000000' : hex(fnv(_gateBasis, bytesOf(v))));
          if (h == 'log_probs' && v != null) logp = fnv(logp, bytesOf(v));
        }
      }
      // one digest over every output of every chunk, in the gate file's order, the same way for the gate's own values
      for (final h in heads12) {
        for (final x in fnvs[h] ?? const <String>[]) {
          digest = fnv(digest, Uint8List.fromList(utf8.encode(x)));
        }
        for (final x in out[h] ?? const []) {
          gateDigest = fnv(gateDigest, Uint8List.fromList(utf8.encode(x as String)));
        }
      }
      final sameHeads = heads12.every((h) {
        final a = fnvs[h] ?? const <String>[];
        final b = out[h] ?? const [];
        return a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
      });
      final same = chunks.length == (e['chunks'] as num).toInt() && hex(logp) == e['logp_fnv'] && sameHeads;
      if (same) {
        identical++;
      } else {
        bad.add('$clip chunks ${chunks.length}/${e['chunks']} logp ${hex(logp) == e['logp_fnv']} '
            'heads ${heads12.where((h) => '${fnvs[h]}' != '${out[h]}').toList()}');
      }
    }
    report('conformance', {
      'clips': expected.length,
      'identical': identical,
      'tokens_same': tokensSame,
      'chunks': chunksAll,
      'digest': hex(digest),
      'gate_digest': hex(gateDigest),
      'ms': DateTime.now().difference(clipsStart).inMilliseconds,
      'bad': bad.take(6).toList(),
    });
    expect(expected, hasLength(35));
    expect(tokensSame, 35);
    expect(identical, 35);
    expect(hex(digest), hex(gateDigest));

    // ---- the accelerator: a take on auto starts its pipeline; the promotion is waited for, then a take on it ----
    final accel = File('${dir.path}/accelerator');
    if (accel.existsSync()) {
      final wait = int.tryParse(accel.readAsStringSync().trim()) ?? 300;
      final e0 = expected.first;
      Future<List<TajweedChunk>> take() async {
        final raw = File('${dir.path}/clips/${e0['clip']}.pcm').readAsBytesSync();
        final s = await model.listenFromSamples(raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4),
            16000, options: const TajweedSessionOptions(context: 'c16_l64', pace: TajweedPace.fast));
        final chunks = await s.chunks.toList();
        await s.finish();
        return chunks;
      }

      final first = await take();
      final a0 = DateTime.now();
      var b = await model.backend();
      final stages = <String>[b.stage.name];
      while (DateTime.now().difference(a0).inSeconds < wait &&
          b.stage != TajweedBackendStage.promoted &&
          b.stage != TajweedBackendStage.demoted) {
        await Future<void>.delayed(const Duration(seconds: 5));
        b = await model.backend();
        if (stages.last != b.stage.name) stages.add(b.stage.name);
      }
      final after = await take();
      report('accelerator', {
        'first_take_backend': '${first.first.backend}',
        'stages': stages,
        'backend': '$b',
        'waited_s': DateTime.now().difference(a0).inSeconds,
        'take_backends': {for (final c in after) '${c.backend.kind.name} ${c.backend.name}'}.toList(),
        'take_tokens': after.isEmpty ? 0 : after.last.decoded.tokens.length,
        'gate_tokens': (e0['tokens'] as List).length,
      });
    }

    // ---- an error the app gets, which the native SDK reports to Quran Lab ----
    if (File('${dir.path}/break_storage').existsSync()) {
      final sdk = sdkDir();
      final models = Directory('${sdk.path}/models');
      final hold = Directory('${sdk.path}/models.e2e-hold');
      await model.close();
      final at = DateTime.now().toUtc();
      models.renameSync(hold.path);
      File(models.path).writeAsStringSync('e2e: a file where the SDK keeps its models folder');
      String code;
      TajweedErrorCause? cause;
      try {
        await client.prefetch();
        code = 'none';
      } on TajweedError catch (err) {
        code = err.code;
        cause = err.cause;
      } finally {
        // The SDK may make the folder again meanwhile (the config's recommended build, written beside the builds): what
        // it wrote goes into the held folder (newer over older), and the held folder is the models folder again.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (FileSystemEntity.typeSync(models.path) == FileSystemEntityType.file) File(models.path).deleteSync();
        if (hold.existsSync()) {
          if (models.existsSync()) {
            for (final e in models.listSync()) {
              final dest = '${hold.path}/${e.path.split('/').last}';
              if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
                FileSystemEntity.isDirectorySync(dest) ? Directory(dest).deleteSync(recursive: true) : File(dest).deleteSync();
              }
              e.renameSync(dest);
            }
            models.deleteSync();
          }
          hold.renameSync(models.path);
        }
      }
      report('error', {
        'code': code,
        'at': at.toIso8601String(),
        'by': 'storage',
        'restored': !hold.existsSync() && models.existsSync(),
        'cause': '$cause',
      });
      expect(code, TajweedErrorCode.storageFailed);
      // 4.0.2: a reported error carries its cause across the channel, the native SDK's tokens
      expect(cause, isNotNull);
      expect(['storage', 'download'], contains(cause!.stage));
      expect(cause.needs, isNull);
      await Future<void>.delayed(const Duration(seconds: 45));
      final d2 = await client.diagnose();
      report('error_sent_window', {'last_error': d2.lastError, 'waited_s': 45});
    }
    if (File('${dir.path}/deny_microphone').existsSync()) {
      final at = DateTime.now().toUtc();
      TajweedErrorCause? cause;
      final code = await model.listen().then<String>((s) async {
        await s.cancel();
        return 'none';
      }, onError: (Object err) {
        if (err is! TajweedError) return '$err';
        cause = err.cause;
        return err.code;
      });
      report('error', {'code': code, 'at': at.toIso8601String(), 'cause': '$cause'});
      expect(code, TajweedErrorCode.microphoneDenied);
      expect(cause?.stage, 'audio');
      expect(cause?.reason, 'permission_denied');
      // the report goes out 30 s after a new occurrence while the app is in front
      await Future<void>.delayed(const Duration(seconds: 45));
      final after = await client.diagnose();
      report('error_sent_window', {'last_error': after.lastError, 'waited_s': 45});
    }

    await model.close();
    await client.close();
    report('done', {});
  }, timeout: const Timeout(Duration(minutes: 30)));
}
