// The web's release check, the same as every platform's (lib/e2e/conformance.dart): the 35 clips through the plugin in
// a browser page, against Quran Lab's servers and the hosted loader. Built as its own entry point
// (`flutter build web -t lib/e2e_web.dart --base-href /<path>/`) and served by a test harness at a path of an origin
// the web key lists; the inputs come from the same path (e2e/key, e2e/expected.jsonl, e2e/clips/<clip>.pcm). The key is
// read by this code and never shown. Each step is appended to `window.__e2e` (JSON lines); `window.__e2eDone` is set
// at the end.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:web/web.dart' as web;

import 'e2e/conformance.dart';

Future<Uint8List> _bytes(String path) async {
  final r = await web.window.fetch(path.toJS).toDart;
  if (r.status != 200) throw StateError('$path: ${r.status}');
  return (await r.arrayBuffer().toDart).toDart.asUint8List();
}

final _lines = <String>[];

void report(String step, Map<String, Object?> data) {
  final line = jsonEncode({'step': step, 'platform': 'web', ...data});
  _lines.add(line);
  globalContext.setProperty('__e2e'.toJS, _lines.join('\n').toJS);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Directionality(textDirection: TextDirection.ltr, child: Center(child: Text('E2E'))));
  try {
    await run();
  } catch (e) {
    report('failed', {'error': e is TajweedError ? '${e.code} ${e.message} ${e.cause}' : '$e'});
  }
  globalContext.setProperty('__e2eDone'.toJS, true.toJS);
}

Future<void> run() async {
  final key = utf8.decode(await _bytes('e2e/key')).trim();
  final t0 = DateTime.now();
  final client = await TajweedClient.create(key);
  var done = 0, total = 0;
  final model = await client.model(onProgress: (d, t) {
    done = d;
    total = t;
  });
  report('open', await openReport(client, model, DateTime.now().difference(t0).inMilliseconds, done, total));
  final d = await client.diagnose();
  report('diagnose', {'json': d.json.length > 4000 ? d.json.substring(0, 4000) : d.json});
  // the loader's own model, read directly: how many sample clips it lists (the plugin maps what it gives)
  final kept = globalContext.getProperty<JSObject>('__quranlabTajweedFormerFlutter'.toJS);
  final jsModel = kept.getProperty<JSObject>('model'.toJS);
  report('sample_clips', {
    'plugin': model.sampleClips.length,
    'loader': (jsModel.getProperty<JSObject>('sampleClips'.toJS).getProperty<JSNumber>('length'.toJS)).toDartInt,
  });

  final expected = expectedOf(utf8.decode(await _bytes('e2e/expected.jsonl')));
  final r = await conformance(model, expected, (clip) async {
    final raw = await _bytes('e2e/clips/$clip.pcm');
    return raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
  });
  report('conformance', r);

  // a sample clip (when the build lists any), a pushed take with ranked tokens, a cancel
  if (model.sampleClips.isEmpty) {
    report('clip', {'sample_clips': 0});
  } else {
    await clipStep(model);
  }
  await pushStep(model, expected);
  await rest(client, model);
}

Future<void> clipStep(TajweedModel model) async {
  final s1 = await model.listenFrom(model.sampleClips.first, options: const TajweedSessionOptions(pace: TajweedPace.fast));
  final events = <TajweedEvent>[];
  final eventsDone = s1.events.forEach(events.add);
  final chunks1 = await s1.chunks.toList();
  await eventsDone;
  final h1 = await s1.finish();
  report('clip', {
    'sample_clips': model.sampleClips.length,
    'chunks': chunks1.length,
    'tokens': h1.decoded().tokens.length,
    'same_text': h1.decoded().text == chunks1.last.decoded.text,
    'ended': events.whereType<TajweedEnded>().map((e) => e.reason.name).toList(),
  });
}

Future<void> pushStep(TajweedModel model, List<Map<String, Object?>> expected) async {
  final e0 = expected.first;
  final raw = await _bytes('e2e/clips/${e0['clip']}.pcm');
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
    'tokens_same': '${[for (final t in h2.greedy()) t.id]}' == '${e0['tokens']}',
    'topK': got.isEmpty || got.last.decoded.frames.isEmpty ? 0 : got.last.decoded.frames.last.topK.length,
  });

  final s3 = await model.session();
  await s3.push(Float32List.sublistView(f, 0, 16000));
  await s3.cancel();
  report('cancel', {
    'finish_after_cancel': await s3.finish().then((_) => 'none', onError: (Object e) => e is TajweedError ? e.code : '$e'),
  });
}

Future<void> rest(TajweedClient client, TajweedModel model) async {
  final ref = model.reference;
  if (ref != null) {
    final u = await ref.units(1, 1);
    report('reference', {'units': u.units.length, 'words': u.wordStarts});
  }
  report('sharing', {
    'available': await client.sharing.isAvailable(),
    'on': await client.sharing.isOn(),
    'items': (await client.sharing.items()).length,
  });
  final storage = await client.storage();
  report('storage', {'models': storage.models.length, 'queue': storage.sharingQueueBytes});
  await model.close();
  await client.close();
  report('done', {});
}
