// SDK 4.0 end to end through the plugin, on an Android device or emulator, the iOS Simulator, an iPhone, a Mac,
// Windows or Linux against Quran Lab's servers (not run by CI: the CI machine has no device and never holds a model).
// Nothing secret is in the app: the inputs go into the app's own folder first (Android: adb push, then `run-as <app id>
// cp` into files/; the iOS Simulator: Documents/ of the container `xcrun simctl get_app_container <device> <bundle id>
// data` gives; an iPhone: `xcrun devicectl device copy to --domain-type appDataContainer` into Documents/; a Mac: the
// app container's Documents/; Windows and Linux: the folder named by QURANLAB_E2E_DIR), and the key is never printed.
// Below, files/ stands for that folder.
//
//   files/e2e/key                the key (on the emulator or the Simulator, a development key: those Core builds are
//                                leased to development keys only; on Windows, Linux and the Mac a desktop key)
//   files/e2e/app_id             optional: the app id the key is registered for (desktop keys), passed as appId
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
// iPhone, with the key's bundle id; a desktop: `flutter test integration_test/e2e_test.dart -d windows|linux`),
// put the inputs in place, start it and read its log (`flutter test` on a phone uninstalls the app at the end). Each
// step prints one line `E2E <json>` and appends it to files/e2e/result.jsonl. The clips' check itself is
// lib/e2e/conformance.dart, the same code the web's run (lib/e2e_web.dart) and the Windows run without a device
// (test/ffi_e2e_test.dart) use.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer_example/e2e/conformance.dart';

/// The app's own files folder without a plugin: on Android from the process name (the app id), on iOS the app
/// container's Documents (the container is the parent of the app's tmp).
Directory filesDir() {
  final dir = Platform.environment['QURANLAB_E2E_DIR'];
  if (dir != null && dir.isNotEmpty) return Directory(dir).parent;
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
    : Platform.isWindows || Platform.isLinux
        ? Directory('${filesDir().path}/e2e/storage')
        : Directory('${filesDir().parent.path}/no_backup/quranlab');

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
    final appIdFile = File('${dir.path}/app_id');
    final desktop = Platform.isWindows || Platform.isLinux;

    // ---- register, the lease, the download, the open ----
    final t0 = DateTime.now();
    final client = await TajweedClient.create(key,
        options: TajweedClientOptions(
          appId: appIdFile.existsSync() ? appIdFile.readAsStringSync().trim() : null,
          storage: desktop ? sdkDir().path : null,
        ));
    var done = 0;
    var total = 0;
    final model = await client.model(onProgress: (d, t) {
      done = d;
      total = t;
    });
    final openMs = DateTime.now().difference(t0).inMilliseconds;
    final d = await client.diagnose();
    report('open', await openReport(client, model, openMs, done, total));
    expect(d.keyAccepted, isTrue);
    expect(d.modelVerified, isTrue);
    expect(d.protectedModel?.lease, 'valid');

    // ---- the 35 clips on the CPU engine, every head of every chunk against the gate's FNV-1a ----
    final expected = expectedOf(File('${dir.path}/expected.jsonl').readAsStringSync());
    final r = await conformance(model, expected, (clip) async {
      final raw = File('${dir.path}/clips/$clip.pcm').readAsBytesSync();
      return raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
    });
    report('conformance', r);
    expect(expected, hasLength(35));
    expect(r['tokens_same'], 35);
    expect(r['identical'], 35);
    expect(r['digest'], r['gate_digest']);

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

    // the SDK's sharing settings over the app (files/e2e/settings present: a person or a screenshot looks at them)
    final settings = File('${dir.path}/settings');
    if (settings.existsSync()) {
      await client.sharing.openSettings();
      report('settings', {'shown': true, 'state_on': await client.sharing.isOn(), 'available': await client.sharing.isAvailable()});
      await Future<void>.delayed(Duration(seconds: int.tryParse(settings.readAsStringSync().trim()) ?? 15));
    }

    await model.close();
    await client.close();
    report('done', {});
  }, timeout: const Timeout(Duration(minutes: 30)));
}
