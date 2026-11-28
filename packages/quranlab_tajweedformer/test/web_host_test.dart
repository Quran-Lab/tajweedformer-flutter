// The web host (lib/src/web/web_host.dart) against a stand-in for Quran Lab's hosted loader (QuranLab.v4, its API 4
// shapes as web/index.d.ts declares them), in a browser: `flutter test --platform chrome test/web_host_test.dart`.
// No request leaves the page: the stand-in answers every call.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer/src/messages.g.dart';
import 'package:quranlab_tajweedformer/src/web/web_host.dart';
import 'package:web/web.dart' as web;

import 'fixtures/errors_40_cases.g.dart';

JSObject obj(Map<String, Object?> m) {
  final o = JSObject();
  for (final e in m.entries) {
    o.setProperty(e.key.toJS, js(e.value));
  }
  return o;
}

// Dart values first: on the JS compilers a type test against a JS interop type is not a test of the value's kind
JSAny? js(Object? v) => switch (v) {
      null => null,
      String() => v.toJS,
      bool() => v.toJS,
      int() => v.toJS,
      double() => v.toJS,
      Float32List() => v.toJS,
      List() => [for (final x in v) js(x)].toJS,
      Map<String, Object?>() => obj(v),
      _ => v as JSAny,
    };

JSPromise<JSAny?> resolved(Object? v) => Future<JSAny?>.value(js(v)).toJS;

/// A JS async iterable over [items], then done.
JSObject iterable(List<JSObject> items) {
  var i = 0;
  final it = obj({});
  it.setProperty(
      'next'.toJS,
      (() => resolved(i < items.length ? {'done': false, 'value': items[i++]} : {'done': true})).toJS);
  final o = obj({});
  final symbol = globalContext.getProperty<JSObject>('Symbol'.toJS).getProperty<JSAny>('asyncIterator'.toJS);
  o.setProperty(symbol, (() => it).toJS);
  return o;
}

JSObject heads(List<double> logProbs, int frames) => obj({
      'names': ['log_probs'],
    })
      ..setProperty(
          'get'.toJS,
          ((JSString name) => obj({
                'name': 'log_probs',
                'kind': 'ctc',
                'frameMs': 40,
                'frames': frames,
                'classes': 2,
                'values': Float32List.fromList(logProbs),
              })).toJS)
      ..setProperty(
          'decoded'.toJS,
          (() => resolved(decoded(3, [1, 2], isFinal: true))).toJS);

JSObject decoded(int frames, List<int> tokens, {bool isFinal = false}) => obj({
      'tokens': [
        for (var i = 0; i < tokens.length; i++)
          {'id': tokens[i], 'name': 't${tokens[i]}', 'firstMs': i * 80, 'peakMs': i * 80 + 40, 'lastMs': i * 80 + 40, 'confidence': 0.75},
      ],
      'frames': [
        for (var f = 0; f < frames; f++)
          {'top1': f % 2, 'top1LogProb': -0.25, 'runnerUp': 1 - f % 2, 'runnerUpLogProb': -2.0, 'margin': 1.75},
      ],
      'settled': tokens.isEmpty ? 0 : tokens.length - 1,
      'isFinal': isFinal,
    });

JSObject backend() => obj({'kind': 'cpu', 'name': 'wasm', 'stage': 'cpu', 'reason': null});

/// The stand-in loader: its calls, recorded.
class Loader {
  final calls = <String>[];
  late final JSObject session;
  late final JSObject model;
  late final JSObject client;
  JSObject? createdWith;
  Object? rejectModelWith;

  void install() {
    session = obj({'backend': backend()});
    session.setProperty('chunks'.toJS,
        iterable([
          obj({'index': 0, 'startMs': 0, 'endMs': 320, 'firstFrame': 0, 'backend': backend(), 'speech': true, 'heads': heads([-0.5, -1, -0.25, -2], 2), 'decoded': decoded(2, [1])}),
          obj({'index': 1, 'startMs': 320, 'endMs': 640, 'firstFrame': 2, 'backend': backend(), 'speech': true, 'heads': heads([-0.5, -1], 1), 'decoded': decoded(3, [1, 2], isFinal: true)}),
        ]));
    session.setProperty('events'.toJS, iterable([obj({'type': 'speechStarted', 'atMs': 40}), obj({'type': 'ended', 'reason': 'sourceEnd'})]));
    session.setProperty('push'.toJS, ((JSFloat32Array s) {
      calls.add('push ${s.toDart.length}');
    }).toJS);
    session.setProperty('finish'.toJS, (() {
      calls.add('finish');
      return resolved(heads([-0.5, -1, -0.25, -2, -0.1, -3], 3));
    }).toJS);
    session.setProperty('cancel'.toJS, (() {
      calls.add('cancel');
      return resolved(null);
    }).toJS);
    session.setProperty('reportRecited'.toJS, ((JSNumber s, JSNumber a, JSNumber b, JSObject o) {
      calls.add('reportRecited ${s.toDartInt}:${a.toDartInt}-${b.toDartInt}');
    }).toJS);

    final tokens = obj({'count': 3, 'blank': 0, 'wordBar': 2})
      ..setProperty('name'.toJS, ((JSNumber i) => ['<b>', 'a', '|'][i.toDartInt].toJS).toJS);
    model = obj({
      'id': 'v4.0',
      'version': '4.0.0',
      'build': 'b' * 40,
      'contexts': ['c16_l64', 'c8_l64'],
      'defaultContext': 'c16_l64',
      'tokens': tokens,
      'calibration': {'text': '{"format":"quranlab.tajweed-calibration/1"}', 'sha256': 'AB12'},
      'reference': null,
      'sampleClips': [
        {'name': 'Husary_001001', 'kind': 'clean', 'durationMs': 5120},
      ],
      'backend': backend(),
    });
    model.setProperty('chunkMs'.toJS, ((JSString c) => (c.toDart == 'c8_l64' ? 160 : 320).toJS).toJS);
    model.setProperty('session'.toJS, ((JSObject o) {
      calls.add('session ${o.getProperty<JSNumber>('sampleRate'.toJS).toDartInt} ${o.getProperty<JSString>('backend'.toJS).toDart}');
      return session;
    }).toJS);
    model.setProperty('listen'.toJS, ((JSObject o) {
      final from = o.getProperty<JSAny?>('from'.toJS);
      calls.add('listen ${from == null ? 'microphone' : from.isA<JSFloat32Array>() ? 'samples' : 'clip'} ${o.getProperty<JSAny?>('pace'.toJS)?.dartify()}');
      return resolved(session);
    }).toJS);
    model.setProperty('close'.toJS, (() => resolved(null)).toJS);

    final sharing = obj({'isAvailable': true, 'isOn': false, 'recoveryCode': null})
      ..setProperty('ask'.toJS, (() => resolved(null)).toJS)
      ..setProperty('items'.toJS,
          (() => resolved([{'id': 'x', 'status': 'uploaded', 'day': '2026-11-22', 'durationMs': 4200, 'bytes': 9000}])).toJS)
      ..setProperty('summary'.toJS,
          (() => resolved({'you': {'sessions': 2, 'minutes': 1.5}, 'app': null, 'all': {'contributors': 9, 'minutes': 99.0}})).toJS);
    client = obj({'sharing': sharing, 'analytics': obj({})});
    client.setProperty('model'.toJS, ((JSAny? v) {
      calls.add('model ${v.dartify()}');
      if (rejectModelWith != null) {
        return globalContext.getProperty<JSObject>('Promise'.toJS).callMethod<JSPromise<JSAny?>>('reject'.toJS, js(rejectModelWith));
      }
      return resolved(model);
    }).toJS);
    client.setProperty('prefetch'.toJS, ((JSObject o) {
      final cb = o.getProperty<JSFunction?>('onProgress'.toJS);
      cb?.callAsFunction(null, obj({'bytesDone': 10, 'bytesTotal': 20}));
      calls.add('prefetch');
      return resolved({'bytesDone': 20, 'bytesTotal': 20, 'complete': true});
    }).toJS);
    client.setProperty('diagnose'.toJS, (() => resolved({'sdk': {'version': '4.0.2'}, 'config': 'fresh'})).toJS);
    client.setProperty('close'.toJS, (() => resolved(null)).toJS);

    final create = obj({});
    create.setProperty('create'.toJS, ((JSObject o) {
      createdWith = o;
      return resolved(client);
    }).toJS);
    globalContext.setProperty('QuranLab'.toJS, obj({'api': 4, 'v4': obj({'TajweedClient': create})}));
  }
}

void main() {
  group('ERRORS_40 through webError, the own layer of the plugin on the web', () {
    // the web SDK makes the error and its errorCause (and replays this vector in its own CI); the plugin turns what
    // it throws into the TajweedError the app gets, and must change nothing on the way
    // a row whose code is none is a silent failure: the SDK makes no error at all, so nothing reaches webError
    for (final row in errors40Causes.where((r) => r.code != 'none')) {
      test('24.13 cause row: ${row.label}', () {
        final e = webError(obj({
          'name': 'TajweedError', 'code': row.code, 'message': row.label, 'fix': 'The fix.',
          'docs': 'https://sdk.quranlab.ai/docs/errors#${row.code}', 'errorCause': row.cause,
        }));
        expect(e.code, row.code);
        expect(e.message, row.label);
        expect(e.fix, 'The fix.');
        expect(e.docs, 'https://sdk.quranlab.ai/docs/errors#${row.code}');
        final c = row.cause;
        if (c == null) {
          expect(e.cause, isNull);
        } else {
          expect(e.cause, isNotNull);
          expect(e.cause!.stage, c['stage']);
          expect(e.cause!.reason, c['reason']);
          expect(e.cause!.httpStatus, c['httpStatus']);
          expect(e.cause!.errorName, c['errorName']);
          expect(e.cause!.errorCode, c['errorCode']);
          expect(e.cause!.needs, c['needs']);
        }
      });
    }

    test('every catalogue code passes through as itself; the API-misuse codes carry no cause', () {
      for (final code in TajweedErrorCode.all) {
        final e = webError(obj({'name': 'TajweedError', 'code': code, 'message': code, 'fix': 'f'}));
        expect(e.code, code);
      }
      for (final code in errors40CodesNotReported) {
        expect(webError(obj({'code': code, 'message': code})).cause, isNull);
      }
      // not the web SDK's error at all: engine_failed with its words, never a crash
      expect(webError('boom'.toJS).code, TajweedErrorCode.engineFailed);
      expect(webError(obj({'code': 'not_a_code', 'message': 'm'})).code, TajweedErrorCode.engineFailed);
    });
  });

  late Loader loader;
  late WebHost host;
  final updates = <UpdateMessage>[];

  setUp(() {
    globalContext.delete('__quranlabTajweedFormerFlutter'.toJS);
    loader = Loader()..install();
    host = WebHost();
    updates.clear();
    host.updates().listen(updates.add);
  });

  test('the client: the key and options go to the loader; the same key again is the same client, another is client_exists',
      () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage(appVersion: '2.1', storage: 'quran', appId: 'ignored'));
    expect(loader.createdWith!.getProperty<JSString>('key'.toJS).toDart, 'qlk_v1_web');
    expect(loader.createdWith!.getProperty<JSString>('storage'.toJS).toDart, 'quran');
    expect(loader.createdWith!.getProperty<JSAny?>('appId'.toJS), isNull);
    // a hot restart: a new host finds the page's client
    final again = WebHost();
    await again.createClient('qlk_v1_web', ClientOptionsMessage());
    final other = await WebHost()
        .createClient('qlk_v1_other', ClientOptionsMessage())
        .then((_) => 'none', onError: (Object e) => (e as TajweedError).code);
    expect(other, TajweedErrorCode.clientExists);
  });

  test('the model: its facts as the loader gives them, progress through prefetch', () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    final m = await host.model(null, 7);
    expect(loader.calls, ['prefetch', 'model null']);
    expect(updates.whereType<ProgressUpdate>().map((u) => '${u.callId} ${u.done}/${u.total}'), ['7 10/20', '7 20/20']);
    expect((m.id, m.version, m.defaultContext), ('v4.0', '4.0.0', 'c16_l64'));
    expect(m.contexts, ['c16_l64', 'c8_l64']);
    expect(m.chunkMs, [320, 160]);
    expect(m.tokens.names, ['<b>', 'a', '|']);
    expect((m.tokens.blank, m.tokens.wordBar), (0, 2));
    expect(m.calibration!.sha256, 'AB12');
    expect(m.hasReference, isFalse);
    expect(m.sampleClips.single.name, 'Husary_001001');
    expect(m.backend.name, 'wasm');
  });

  test('a failure is the web SDK\'s error: its code, fix, docs and errorCause', () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    loader.rejectModelWith = obj({
      'name': 'TajweedError',
      'code': 'needs_connection',
      'message': 'no answer',
      'fix': 'Connect.',
      'docs': 'https://sdk.quranlab.ai/docs/errors#needs_connection',
      'errorCause': {'stage': 'download', 'reason': 'network', 'needs': 'model'},
    });
    final e = await host.model(null, null).then<TajweedError?>((_) => null, onError: (Object e) => e as TajweedError);
    expect((e!.code, e.message, e.fix), ('needs_connection', 'no answer', 'Connect.'));
    expect(e.cause, const TajweedErrorCause(stage: 'download', reason: 'network', needs: 'model'));
  });

  test('a pushed take: its chunks as deltas, its events, its end; finish gives the heads', () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    await host.model(null, null);
    await host.openSession(5, 'push', SessionOptionsMessage(sampleRate: 16000, backend: 'coreml-compact', topK: 0, pace: 'realTime'),
        null, null, null);
    expect(loader.calls.last, 'session 16000 auto');
    await host.push(5, Int16List.fromList([0, 16384, -32768]).buffer.asUint8List(), true);
    expect(loader.calls.last, 'push 3');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final chunks = updates.whereType<ChunkUpdate>().toList();
    expect(chunks.map((c) => c.chunk.index), [0, 1]);
    expect(chunks[1].chunk.decoded.tokenStart, 1, reason: 'the first token was sent with chunk 0');
    expect(chunks[1].chunk.decoded.frameStart, 2);
    expect(chunks[0].chunk.heads.single.values.buffer.asFloat32List(), [-0.5, -1, -0.25, -2]);
    expect(updates.whereType<EventUpdate>().map((e) => e.event.type), ['speechStarted', 'ended']);
    expect(updates.last, isA<ClosedUpdate>());
    final h = await host.finish(5);
    expect(h.heads.single.frames, 3);
    expect(h.decoded.tokenIds, [1, 2]);
    expect(h.decoded.isFinal, isTrue);
    await host.reportRecited(5, 1, 1, 7, null, const []);
    expect(loader.calls.last, 'reportRecited 1:1-7');
  });

  test('a clip and samples go to listen({from}) with their pace; a clip the model does not list is invalid_argument',
      () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    await host.model(null, null);
    final o = SessionOptionsMessage(sampleRate: 16000, backend: 'auto', topK: 0, pace: 'fast');
    await host.openSession(1, 'clip', o, 'Husary_001001', null, null);
    expect(loader.calls.last, 'listen clip fast');
    await host.openSession(2, 'samples', o, null, Float32List(4).buffer.asUint8List(), 16000);
    expect(loader.calls.last, 'listen samples fast');
    final e = await host.openSession(3, 'clip', o, 'nope', null, null).then((_) => '', onError: (Object e) => (e as TajweedError).code);
    expect(e, TajweedErrorCode.invalidArgument);
  });

  test('sharing: an ask with none due is false; the outbox and the summary as the web SDK gives them; the theme as CSS',
      () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    expect(await host.sharingAsk(), isFalse);
    final s = await host.sharingState();
    expect((s.available, s.on, s.recoveryCode), (true, false, null));
    final items = await host.sharingItems();
    expect((items.single.status, items.single.day, items.single.durationMs, items.single.bytes), ('uploaded', '2026-11-22', 4200, 9000));
    final sum = await host.sharingSummary();
    expect((sum!.mySessions, sum.myMinutes, sum.appContributors, sum.allContributors), (2, 1.5, null, 9));
    await host.sharingSetTheme(SharingThemeMessage(accent: 0xFF0A66FF, cornerRadius: 16));
    final style = (web.document.documentElement! as web.HTMLElement).style;
    expect(style.getPropertyValue('--ql-accent'), 'rgb(10 102 255 / 1.000)');
    expect(style.getPropertyValue('--ql-radius'), '16px');
  });

  test('diagnose is the web SDK\'s report as JSON', () async {
    await host.createClient('qlk_v1_web', ClientOptionsMessage());
    expect(TajweedDiagnosis.fromJson(await host.diagnose()).sdkVersion, '4.0.2');
  });
}
