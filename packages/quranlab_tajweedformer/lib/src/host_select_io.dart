// The native platforms' hosts: Windows and Linux run the C SDK through dart:ffi; Android and iOS answer Pigeon's
// channels. Internal.
import 'dart:io';

import 'ffi/ffi_host.dart';
import 'host.dart';

/// The host of this platform. A `flutter test` run on the host machine talks to the channels the tests answer
/// (as on a phone), whatever the machine; a test of the C SDK sets `Bridge.debugHost` itself.
TajweedHost platformHost() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return PigeonHost();
  if (Platform.isWindows || Platform.isLinux) return FfiHost();
  return PigeonHost();
}
