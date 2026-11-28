// Windows and Linux: the app's own id and version when TajweedClientOptions leaves them null, as Android and iOS take
// the package name and the bundle id. The C SDK requires an app id: the one registered for the desktop key.
//
// - Windows: the package family name of a packaged (MSIX) app, else the process's explicit AppUserModelID, else none;
//   the version is the program's ProductVersion (Flutter's Runner.rc: the pubspec's `version`, `1.2.3+45`).
// - Linux: the GTK application id of the Flutter runner (APPLICATION_ID in linux/CMakeLists.txt); no version.
//
// Internal.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

abstract final class AppIdentity {
  /// The app's id, or null when the platform gives none (the app must then pass `appId`).
  static String? appId() {
    try {
      return Platform.isWindows ? _windowsId() : _linuxId();
    } catch (_) {
      return null;
    }
  }

  /// The app's version (`1.2.3`), or null.
  static String? version() => _versionParts()?.$1;

  /// The app's build number (`45`), or null.
  static String? build() => _versionParts()?.$2;

  static (String, String?)? _versionParts() {
    if (!Platform.isWindows) return null;
    try {
      final v = productVersionOf(Platform.resolvedExecutable);
      if (v == null || v.isEmpty) return null;
      final plus = v.indexOf('+');
      return plus < 0 ? (v, null) : (v.substring(0, plus), v.substring(plus + 1));
    } catch (_) {
      return null;
    }
  }

  // ---- Windows ----

  static String? _windowsId() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getFamily = kernel32.lookupFunction<Int32 Function(Pointer<Uint32>, Pointer<Utf16>),
        int Function(Pointer<Uint32>, Pointer<Utf16>)>('GetCurrentPackageFamilyName');
    final len = calloc<Uint32>()..value = 0;
    try {
      // ERROR_INSUFFICIENT_BUFFER (122) with the length: the app has a package identity
      if (getFamily(len, nullptr) == 122 && len.value > 0) {
        final name = calloc<Uint16>(len.value).cast<Utf16>();
        try {
          if (getFamily(len, name) == 0) return name.toDartString();
        } finally {
          calloc.free(name);
        }
      }
    } finally {
      calloc.free(len);
    }
    final shell32 = DynamicLibrary.open('shell32.dll');
    final getAumid = shell32.lookupFunction<Int32 Function(Pointer<Pointer<Utf16>>), int Function(Pointer<Pointer<Utf16>>)>(
        'GetCurrentProcessExplicitAppUserModelID');
    final out = calloc<Pointer<Utf16>>();
    try {
      if (getAumid(out) == 0 && out.value != nullptr) {
        final id = out.value.toDartString();
        final ole32 = DynamicLibrary.open('ole32.dll');
        ole32.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree')(out.value.cast());
        return id.isEmpty ? null : id;
      }
    } finally {
      calloc.free(out);
    }
    return null;
  }

  /// The ProductVersion of a Windows program's version resource (the first translation it lists, then Flutter's
  /// Runner.rc block), or null.
  static String? productVersionOf(String program) {
    final version = DynamicLibrary.open('version.dll');
    final size = version.lookupFunction<Uint32 Function(Pointer<Utf16>, Pointer<Uint32>), int Function(Pointer<Utf16>, Pointer<Uint32>)>(
        'GetFileVersionInfoSizeW');
    final info = version.lookupFunction<Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>)>('GetFileVersionInfoW');
    final query = version.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>, Pointer<Uint32>)>('VerQueryValueW');
    final arena = Arena();
    try {
      final exe = program.toNativeUtf16(allocator: arena);
      final handle = arena<Uint32>();
      final n = size(exe, handle);
      if (n == 0) return null;
      final data = arena<Uint8>(n).cast<Void>();
      if (info(exe, 0, n, data) == 0) return null;
      final out = arena<Pointer<Void>>();
      final len = arena<Uint32>();
      // the first translation the file lists, then Flutter's Runner.rc block
      final blocks = <String>[];
      if (query(data, r'\VarFileInfo\Translation'.toNativeUtf16(allocator: arena), out, len) != 0 && len.value >= 4) {
        final t = out.value.cast<Uint16>();
        blocks.add('${t[0].toRadixString(16).padLeft(4, '0')}${t[1].toRadixString(16).padLeft(4, '0')}');
      }
      blocks.add('040904e4');
      for (final b in blocks) {
        if (query(data, '\\StringFileInfo\\$b\\ProductVersion'.toNativeUtf16(allocator: arena), out, len) != 0 &&
            len.value > 0) {
          return out.value.cast<Utf16>().toDartString().trim();
        }
      }
      return null;
    } finally {
      arena.releaseAll();
    }
  }

  // ---- Linux ----

  static String? _linuxId() {
    final gio = DynamicLibrary.open('libgio-2.0.so.0');
    final getDefault = gio.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('g_application_get_default');
    final getId = gio.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
        'g_application_get_application_id');
    final app = getDefault();
    if (app == nullptr) return null;
    final id = getId(app);
    if (id == nullptr) return null;
    final s = id.toDartString();
    return s.isEmpty ? null : s;
  }
}
