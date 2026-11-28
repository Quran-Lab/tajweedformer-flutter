// The live hosted loader, keyless: the web host loads Quran Lab's loader as an app's page would (its hosts in the npm
// wrapper's order), and the API 4 object it gives has every class and method lib/src/web/web_host.dart calls. No key,
// no client, no model: a change of the loader's names fails here before an app finds it.
// Run: `flutter test --platform chrome test/web_loader_live_test.dart` (needs the network). CI runs it in the web job.
@TestOn('browser')
@Tags(['live'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/src/web/web_host.dart';

/// What web_host.dart calls on each class's prototype (statics on the class itself), as web 4.0.2's index.d.ts
/// declares them.
const _methods = {
  'TajweedClient': ['model', 'prefetch', 'storage', 'removeModels', 'diagnose', 'close'],
  'TajweedModel': ['listen', 'session', 'close'],
  'TajweedSession': ['push', 'finish', 'cancel', 'reportRecited'],
  'TajweedHeads': ['decoded'],
};

bool _isFunction(JSAny? v) => v != null && v.typeofEquals('function');

void main() {
  test('the hosted loader gives API 4 with the classes and methods the web host calls', () async {
    final api = await WebHost.loadApiForTest().timeout(const Duration(seconds: 60));
    final q = globalContext.getProperty<JSObject>('QuranLab'.toJS);
    expect(q.getProperty<JSNumber>('api'.toJS).toDartInt, 4);
    final version = api.getProperty<JSString?>('version'.toJS)?.toDart;
    expect(version, startsWith('4.'), reason: 'the loader names its SDK version (got $version)');

    final missing = <String>[];
    final client = api.getProperty<JSAny?>('TajweedClient'.toJS);
    if (!_isFunction((client as JSObject?)?.getProperty<JSAny?>('create'.toJS))) missing.add('TajweedClient.create');
    for (final e in _methods.entries) {
      final cls = api.getProperty<JSAny?>(e.key.toJS);
      if (!_isFunction(cls)) {
        missing.add(e.key);
        continue;
      }
      final proto = (cls as JSObject).getProperty<JSObject>('prototype'.toJS);
      for (final m in e.value) {
        if (!_isFunction(proto.getProperty<JSAny?>(m.toJS))) missing.add('${e.key}.$m');
      }
    }
    expect(_isFunction(api.getProperty<JSAny?>('TajweedError'.toJS)), isTrue, reason: 'TajweedError');
    expect(missing, isEmpty, reason: 'the loader ($version) lacks what the web host calls');
    // ignore: avoid_print
    print('LIVE loader API 4, SDK $version: ${_methods.values.fold<int>(1, (n, l) => n + l.length)} members checked');
  });
}
