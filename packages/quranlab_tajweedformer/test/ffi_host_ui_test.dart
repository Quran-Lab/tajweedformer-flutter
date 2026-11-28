// Windows and Linux: the C SDK's calls that wait (for the network, or for the Client's lock that a download holds)
// never run on the UI isolate, and the Client outlives every call that uses it. No real library: a stand-in for the
// C SDK whose symbols are Dart functions behind native pointers (NativeCallable), so FfiHost calls them exactly as it
// calls tajweedformer.dll; each one that waits in the real SDK sleeps here. Every isolate that opens the libraries
// makes its own stand-in, as TfNative.open does, and every call is written to a log with the isolate it ran on.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/ffi/ffi_host.dart';
import 'package:quranlab_tajweedformer/src/ffi/native.dart';
import 'package:quranlab_tajweedformer/src/ffi/tajweedformer.g.dart';

/// How long a call of the stand-in that waits in the real SDK takes.
const _slow = Duration(milliseconds: 600);

/// True on the test's own isolate (the app's UI isolate); top-level state is per isolate, so false everywhere else.
bool _ui = false;

final _log = File('${Directory.systemTemp.path}${Platform.pathSeparator}quranlab_ffi_host_ui_test_$pid.log');

void _note(String call) =>
    _log.writeAsStringSync('${_ui ? 'ui' : 'other'}\t$call\n', mode: FileMode.append, flush: true);

/// The calls in the order they were made: (the isolate, the call).
List<(String, String)> _calls() => [
      for (final l in _log.readAsLinesSync())
        if (l.isNotEmpty) (l.split('\t')[0], l.split('\t')[1]),
    ];

Pointer<Char> _text(String s) => s.toNativeUtf8().cast<Char>();

int _background(Pointer<TfClient> c) {
  _note('tf_client_background');
  sleep(_slow); // the telemetry is sent; then the ask in hand is taken back
  _note('tf_client_background end');
  return 0;
}

int _ask(Pointer<TfClient> c) {
  _note('tf_sharing_ask');
  return 0; // no ask due
}

int _status(Pointer<TfClient> c, Pointer<TfSharing> out) => 0; // nothing pending (the caller's struct is zeroed)

int _foreground(Pointer<TfClient> c) {
  _note('tf_client_foreground');
  sleep(_slow); // the config is asked for
  return 0;
}

Pointer<Char> _items(Pointer<TfClient> c) {
  _note('tf_sharing_items_json');
  sleep(_slow); // the Client's lock, held by a download
  return _text('[{"created": 1764201600, "completed": true}]');
}

Pointer<Char> _storage(Pointer<TfClient> c) {
  _note('tf_client_storage_json start');
  sleep(_slow);
  _note('tf_client_storage_json end');
  return _text('{"models": [], "sharingQueueBytes": 0}');
}

void _destroy(Pointer<TfClient> c) => _note('tf_client_destroy');

final Map<String, Pointer> _symbols = {};
final Map<int, int> _slots = {};
TfNative? _standIn;

Pointer<T> _lookup<T extends NativeType>(String name) => (_symbols[name] ??= switch (name) {
      'tf_client_background' =>
        NativeCallable<Int Function(Pointer<TfClient>)>.isolateLocal(_background, exceptionalReturn: -1).nativeFunction,
      'tf_client_foreground' =>
        NativeCallable<Int Function(Pointer<TfClient>)>.isolateLocal(_foreground, exceptionalReturn: -1).nativeFunction,
      'tf_sharing_ask' => NativeCallable<Int Function(Pointer<TfClient>)>.isolateLocal(_ask, exceptionalReturn: -1).nativeFunction,
      'tf_sharing_status' => NativeCallable<Int Function(Pointer<TfClient>, Pointer<TfSharing>)>.isolateLocal(_status,
              exceptionalReturn: -1)
          .nativeFunction,
      'tf_sharing_items_json' => NativeCallable<Pointer<Char> Function(Pointer<TfClient>)>.isolateLocal(_items).nativeFunction,
      'tf_client_storage_json' =>
        NativeCallable<Pointer<Char> Function(Pointer<TfClient>)>.isolateLocal(_storage).nativeFunction,
      'tf_client_destroy' => NativeCallable<Void Function(Pointer<TfClient>)>.isolateLocal(_destroy).nativeFunction,
      _ => throw StateError('the stand-in has no $name'),
    })
        .cast<T>();

/// The libraries of the isolate that calls it: top-level, so FfiHost can send it to its short-lived isolates.
TfNative _openStandIn() => _standIn ??= TfNative.forTest(TfBindings.fromLookup(_lookup), (s) => _slots[s] ?? 0, (s, v) {
      final before = _slots[s] ?? 0;
      _slots[s] = v;
      return before;
    });

FfiHost _host() => FfiHost(openNative: _openStandIn)..adoptClientForTest(0x1000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _ui = true;
  setUp(() => _log.writeAsStringSync(''));
  tearDownAll(() {
    if (_log.existsSync()) _log.deleteSync();
  });

  test('leaving the foreground and coming back waits for nothing on the UI isolate, and the two calls keep their order',
      () async {
    final host = _host();
    final sw = Stopwatch()..start();
    // minimized and restored, as Windows reports it (paused and a second hidden change nothing more)
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      host.didChangeAppLifecycleState(s);
    }
    expect(sw.elapsed, lessThan(_slow ~/ 3), reason: 'the window must not freeze while the SDK reaches Quran Lab');
    await host.lifecycleSettled;
    expect(_calls(),
        [('other', 'tf_client_background'), ('other', 'tf_client_background end'), ('other', 'tf_client_foreground')]);
  });

  test('an ask right after the window came back waits until the SDK took the old ask back', () async {
    final host = _host();
    host
      ..didChangeAppLifecycleState(AppLifecycleState.hidden)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(await host.sharingAsk(), isFalse);
    await host.lifecycleSettled;
    final calls = _calls().map((c) => c.$2).toList();
    expect(calls, containsAll(['tf_client_background end', 'tf_sharing_ask']));
    // asked before the background call returned, an ask would be taken back under a sheet that stays on screen
    expect(calls.indexOf('tf_sharing_ask'), greaterThan(calls.indexOf('tf_client_background end')));
  });

  test('a window that only loses and regains the focus has not left the foreground: nothing is called', () async {
    final host = _host();
    host
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed)
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    await host.lifecycleSettled;
    expect(_calls(), isEmpty);
  });

  test('the sharing queue is read off the UI isolate: the UI keeps running while the Client\'s lock is held', () async {
    final host = _host();
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) => ticks++);
    final sw = Stopwatch()..start();
    final pending = host.sharingItems();
    expect(sw.elapsed, lessThan(_slow ~/ 3));
    final items = await pending;
    timer.cancel();
    expect(ticks, greaterThanOrEqualTo(2), reason: 'the UI isolate ran while the items were read');
    expect(items.single.status, 'uploaded');
    expect(items.single.day, '2025-11-27');
    expect(_calls(), [('other', 'tf_sharing_items_json')]);
  });

  test('a Client another engine of the process closed already is not freed again', () async {
    final first = _host(), second = _host(); // a debug build's second window takes the same Client
    await first.closeClient();
    await second.closeClient();
    expect(_calls().map((c) => c.$2), ['tf_client_destroy']);
  });

  test('closing the client waits for a call that still uses it before freeing it', () async {
    final host = _host();
    final storage = host.storage();
    await host.closeClient();
    await storage;
    expect(_calls().map((c) => c.$2), ['tf_client_storage_json start', 'tf_client_storage_json end', 'tf_client_destroy']);
  });
}
