// Windows and Linux: the app's own id and version when the app passes none (lib/src/ffi/app_identity.dart), read from
// the system through dart:ffi. Here the program is the test runner, which has no package identity (Windows) and no
// GApplication (Linux): the calls must answer null or the runner's own version, never fail.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/ffi/app_identity.dart';

void main() {
  final desktop = Platform.isWindows || Platform.isLinux;

  test('the app id: none for a program without a package identity or a GApplication', () {
    expect(AppIdentity.appId(), isNull);
  }, skip: !desktop);

  test('the version and build: the program\'s ProductVersion on Windows, none on Linux', () {
    final v = AppIdentity.version(), b = AppIdentity.build();
    // ignore: avoid_print
    print('version $v build $b');
    if (Platform.isLinux) {
      expect(v, isNull);
      expect(b, isNull);
    } else if (v != null) {
      expect(v, isNot(contains('+')));
      expect(v.trim(), v);
    }
  }, skip: !desktop);

  test("the version lookup reads a program's ProductVersion (a system program that has one)", () {
    final windir = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final v = AppIdentity.productVersionOf('$windir\\System32\\notepad.exe');
    // ignore: avoid_print
    print('notepad $v');
    expect(v, matches(RegExp(r'^\d+(\.\d+)+$')));
    expect(AppIdentity.productVersionOf('$windir\\no-such-program.exe'), isNull);
  }, skip: !Platform.isWindows);
}
