import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
import 'package:quranlab_tajweedformer/src/messages.g.dart';

import 'fake_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;

  // one stand-in for the whole file: the plugin listens to the update channel once per isolate, as in an app
  setUpAll(() => native = FakeNative());

  setUp(() {
    native.calls.clear();
    native.ok(['createClient', 'closeClient', 'closeModel', 'openSession', 'cancel', 'reportRecited']);
    native.on('model', (_) => modelMessage());
  });

  tearDown(() async {
    await TajweedClient.current?.close();
    native.reset();
  });

  Future<(TajweedClient, TajweedModel)> open() async {
    final client = await TajweedClient.create('qlk_v1_test');
    return (client, await client.model());
  }

  group('client', () {
    test('create sends the key and options; the same key gives the same client', () async {
      final a = await TajweedClient.create('qlk_v1_test',
          options: const TajweedClientOptions(appVersion: '2.1', storage: '/data/tf'));
      final b = await TajweedClient.create('qlk_v1_test');
      expect(identical(a, b), isTrue);
      expect(native.calls.where((c) => c.$1 == 'createClient'), hasLength(1));
      final args = native.calls.first.$2;
      expect(args[0], 'qlk_v1_test');
      final options = args[1] as ClientOptionsMessage;
      expect(options.appVersion, '2.1');
      // the three options are all the native side gets: appId, appVersion, storage
      expect(options.encode(), [null, '2.1', '/data/tf']);
    });

    test('another key while a client is open is client_exists', () async {
      await TajweedClient.create('qlk_v1_test');
      await expectLater(TajweedClient.create('qlk_v1_other'),
          throwsA(isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.clientExists)));
    });

    test('a native refusal is a TajweedError with the SDK code, fix and docs', () async {
      native.on('createClient', (_) => throw sdkError('invalid_key', 'The key is not accepted.', 'Copy the key again.'));
      final e = await TajweedClient.create('qlk_v1_bad').then<Object>((_) => 'no error', onError: (Object e) => e);
      expect(e, isA<TajweedError>());
      final err = e as TajweedError;
      expect(err.code, 'invalid_key');
      expect(err.message, 'The key is not accepted.');
      expect(err.fix, 'Copy the key again.');
      expect(err.docs, 'https://sdk.quranlab.ai/docs/errors#invalid_key');
      expect(TajweedClient.current, isNull);
    });

    test('a platform with no native side is runtime_unsupported', () async {
      native.reset();
      await expectLater(TajweedClient.create('qlk_v1_test'),
          throwsA(isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.runtimeUnsupported)));
    });

    test('model() reports the download progress and opens the model', () async {
      native.on('model', (args) async {
        final id = args[1] as int;
        native.emit(ProgressUpdate(callId: id, done: 10, total: 100));
        native.emit(ProgressUpdate(callId: id, done: 100, total: 100));
        await Future<void>.delayed(Duration.zero);
        return modelMessage();
      });
      final client = await TajweedClient.create('qlk_v1_test');
      final seen = <(int, int)>[];
      final model = await client.model(onProgress: (d, t) => seen.add((d, t)));
      expect(seen, [(10, 100), (100, 100)]);
      expect(model.version, '4.0.0');
      expect(model.chunkMs(), 320);
      expect(model.chunkMs('c8_l64'), 160);
      expect(() => model.chunkMs('c99'), throwsA(isA<TajweedError>()));
      expect(model.tokens.name(2), 'b');
      expect(model.tokens.id('|'), 3);
      expect(model.sampleClips.single.name, '001001');
      expect(model.reference, isNull);
    });

    test('a pinned version asks for no progress', () async {
      final client = await TajweedClient.create('qlk_v1_test');
      await client.model(version: '4.0.0', onProgress: (_, _) {});
      final args = native.calls.lastWhere((c) => c.$1 == 'model').$2;
      expect(args[0], '4.0.0');
    });

    test('diagnose() reads the report every SDK writes', () async {
      native.on('diagnose', (_) => '{"sdk": {"version": "3.1.5", "latest": "3.1.5"}, "key": {"accepted": false, '
          '"reason": "server_rejected"}, "config": "fresh", "model": {"version": "4.0.0", "build": "abc", "verified": true}, '
          '"context": "c16_l64", "backend": {"kind": "accelerator", "name": "coreml", "stage": "promoted", "reason": null}, '
          '"microphone": "granted", "storage": {"models": [], "sharingQueueBytes": 0}, "lastError": "invalid_key", '
          '"droppedChunks": 3, "connection": "unmetered", "protected": {"keyStore": "strongbox", "lease": "grace", '
          '"leaseExpires": 1795600000, "leaseClass": "attested", "refreshAfter": 1795100000, "graceUntil": 1795686400, '
          '"core": "4.0.0-c3 android-arm64-v8a"}}');
      final (client, _) = await open();
      final d = await client.diagnose();
      expect(d.sdkVersion, '3.1.5');
      expect(d.keyAccepted, isFalse);
      expect(d.keyReason, 'server_rejected');
      expect(d.modelVerified, isTrue);
      expect(d.backend?.kind, TajweedBackendKind.accelerator);
      expect(d.backend?.stage, TajweedBackendStage.promoted);
      expect(d.droppedChunks, 3);
      expect(d.downloadProtocol, isNull);
      final p = d.protectedModel!;
      expect((p.keyStore, p.lease, p.leaseClass, p.core), ('strongbox', 'grace', 'attested', '4.0.0-c3 android-arm64-v8a'));
      expect((p.leaseExpires, p.refreshAfter, p.graceUntil), (1795600000, 1795100000, 1795686400));
      expect(d.json, contains('"lastError": "invalid_key"'));
    });

    test('diagnose() passes the hosts in use and the last failover through (native SDK 4.0.1, contract 28.7)', () async {
      native.on('diagnose', (_) => '{"sdk": {"version": "4.0.1"}, "config": "fresh", "endpoints": {"api": '
          '"api-b.tajweedformer.com", "models": "cdn.quranlab.ai", "lastFailover": {"role": "api", "from": '
          '"api.quranlab.ai", "to": "api-b.tajweedformer.com", "reason": "http", "status": 503, "at": 1795600000}}}');
      final (client, _) = await open();
      final d = await client.diagnose();
      final e = d.endpoints!;
      expect((e.api, e.models), ('api-b.tajweedformer.com', 'cdn.quranlab.ai'));
      final f = e.lastFailover!;
      expect((f.role, f.from, f.to, f.reason, f.status, f.at),
          ('api', 'api.quranlab.ai', 'api-b.tajweedformer.com', 'http', 503, 1795600000));
      expect(d.json, contains('"lastFailover"'));
      native.on('diagnose', (_) => '{"sdk": {"version": "4.0.1"}, "endpoints": {"api": "api.quranlab.ai", '
          '"models": "cdn.quranlab.ai", "lastFailover": null}}');
      final quiet = (await client.diagnose()).endpoints!;
      expect((quiet.api, quiet.lastFailover), ('api.quranlab.ai', null));
      native.on('diagnose', (_) => '{"sdk": {"version": "4.0.0"}}');
      expect((await client.diagnose()).endpoints, isNull);
    });

    test('a diagnosis without the protected object (a client with no key) has none; a lease before any is none',
        () async {
      native.on('diagnose', (_) => '{"sdk": {"version": "4.0.0"}, "config": "none"}');
      final (client, _) = await open();
      expect((await client.diagnose()).protectedModel, isNull);
      native.on('diagnose', (_) => '{"sdk": {"version": "4.0.0"}, "protected": {"keyStore": null, "lease": "none", '
          '"leaseExpires": null, "leaseClass": null, "refreshAfter": null, "graceUntil": null, "core": null}}');
      final p = (await client.diagnose()).protectedModel!;
      expect((p.lease, p.keyStore, p.leaseExpires, p.graceUntil), ('none', null, null, null));
    });
  });

  group('a take', () {
    test('chunks rebuild the decoded layer from deltas, events map, the end closes both streams', () async {
      final (_, model) = await open();
      late int id;
      native.on('openSession', (args) {
        id = args[0] as int;
        expect(args[1], 'listen');
        expect((args[2] as SessionOptionsMessage).endOnSilenceMs, 1500);
        return null;
      });
      final session = await model.listen(options: const TajweedSessionOptions(endOnSilenceMs: 1500));
      final chunks = <TajweedChunk>[];
      final events = <TajweedEvent>[];
      final chunksDone = Completer<void>();
      final eventsDone = Completer<void>();
      session.chunks.listen(chunks.add, onDone: chunksDone.complete);
      session.events.listen(events.add, onDone: eventsDone.complete);

      native.emit(EventUpdate(sessionId: id, event: EventMessage(type: 'speechStarted', atMs: 40)));
      // tokens a | b, the first two settled
      native.emit(ChunkUpdate(sessionId: id, chunk: chunkMessage(0, delta(ids: [1, 3, 2], frames: 8, settled: 2))));
      // only the tail changed: b becomes a, and a new b; 8 new frames
      native.emit(ChunkUpdate(
          sessionId: id, chunk: chunkMessage(1, delta(tokenStart: 2, ids: [1, 2], frameStart: 8, frames: 8, settled: 4))));
      native.emit(EventUpdate(sessionId: id, event: EventMessage(type: 'ended', reason: 'silence')));
      native.emit(ClosedUpdate(sessionId: id));
      await chunksDone.future;
      await eventsDone.future;

      expect(chunks, hasLength(2));
      final first = chunks[0].decoded;
      final second = chunks[1].decoded;
      expect(first.text, 'a | b');
      expect(first.frames, hasLength(8));
      expect(second.text, 'a | a b');
      expect(second.settled, 4);
      expect(second.frames, hasLength(16));
      expect(second.frames.last.index, 15);
      expect(second.frames.last.startMs, 600);
      expect(second.frames.first.runnerUpLogProb, -2.6);
      expect(second.words.map((w) => w.text), ['a', 'a b']);
      // a chunk the app already has never changes
      expect(first.tokens.map((t) => t.name), ['a', '|', 'b']);
      expect(first.frames, hasLength(8));
      // NaN on the wire is "no confidence"
      expect(second.tokens[1].confidence, isNull);
      expect(second.tokens[0].confidence, 0.9);
      expect(events.first, isA<TajweedSpeechStarted>().having((e) => e.atMs, 'atMs', 40));
      expect(events.last, isA<TajweedEnded>().having((e) => e.reason, 'reason', TajweedEndReason.silence));
    });

    test('a replay after a change of backend replaces the frames from its chunk, older chunks keep theirs', () async {
      final (_, model) = await open();
      late int id;
      native.on('openSession', (args) => id = args[0] as int);
      final session = await model.session();
      final chunks = <TajweedChunk>[];
      final done = Completer<void>();
      session.chunks.listen(chunks.add, onDone: done.complete);
      native.emit(ChunkUpdate(sessionId: id, chunk: chunkMessage(0, delta(ids: [1], frames: 8))));
      native.emit(ChunkUpdate(sessionId: id, chunk: chunkMessage(1, delta(tokenStart: 1, ids: [2], frameStart: 8, frames: 8))));
      native.emit(EventUpdate(
          sessionId: id,
          event: EventMessage(
              type: 'backendChanged', backend: BackendMessage(kind: 'cpu', name: 'cpu', stage: 'demoted'), fromChunk: 1)));
      native.emit(ChunkUpdate(
          sessionId: id, chunk: chunkMessage(1, delta(tokenStart: 1, ids: [1], frameStart: 8, frames: 8, topFrom: 2))));
      native.emit(ClosedUpdate(sessionId: id));
      await done.future;
      expect(chunks, hasLength(3));
      expect(chunks[1].decoded.frames[8].top, 1);
      expect(chunks[2].decoded.frames[8].top, 2);
      expect(chunks[2].decoded.frames, hasLength(16));
      expect(chunks[2].decoded.text, 'a a');
    });

    test('pushes reach the native side in order, as float32 or int16 bytes, before finish', () async {
      final (_, model) = await open();
      final order = <int>[];
      var slow = true;
      native.on('push', (args) async {
        final bytes = args[1] as Uint8List;
        // the first push answers late: the second must still arrive after it
        if (slow) {
          slow = false;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        order.add(bytes.length);
        return null;
      });
      native.on('finish', (_) => HeadsMessage(heads: [], decoded: delta(ids: [1, 2], frames: 2, settled: 2, isFinal: true)));
      final session = await model.session(options: const TajweedSessionOptions(sampleRate: 16000));
      final samples = Float32List.fromList([0.5, -0.25]);
      final a = session.push(samples);
      samples[0] = 0; // the app reuses its buffer: what was pushed is kept
      final b = session.pushInt16(Int16List.fromList([1, 2, 3]));
      final heads = await session.finish();
      await Future.wait([a, b]);
      expect(order, [8, 6]);
      final first = native.calls.firstWhere((c) => c.$1 == 'push').$2;
      final pushed = ByteData.sublistView(first[1] as Uint8List);
      expect(pushed.getFloat32(0, Endian.little), 0.5);
      expect(first[2], isFalse);
      expect(native.calls.lastWhere((c) => c.$1 == 'push').$2[2], isTrue);
      expect(native.calls.last.$1, 'finish');
      expect(heads.decoded().isFinal, isTrue);
      expect(heads.decoded().text, 'a b');
    });

    test('a listen session takes no pushes', () async {
      final (_, model) = await open();
      final session = await model.listen();
      await expectLater(session.push(Float32List(4)),
          throwsA(isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.sessionClosed)));
    });

    test('a refused microphone is microphone_denied and the take is not kept', () async {
      final (_, model) = await open();
      native.on('openSession', (_) => throw sdkError('microphone_denied', 'The microphone was refused.', 'Ask again.'));
      await expectLater(model.listen(),
          throwsA(isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.microphoneDenied)));
    });

    test('heads are float32 views; greedy runs the Android definition with the chunk offset', () async {
      final (_, model) = await open();
      late int id;
      native.on('openSession', (args) => id = args[0] as int);
      final session = await model.listenFrom(model.sampleClips.first);
      expect(native.calls.lastWhere((c) => c.$1 == 'openSession').$2[3], '001001');
      final got = Completer<TajweedChunk>();
      session.chunks.listen(got.complete);
      // 3 frames x 4 classes: a, a, blank
      final lp = HeadMessage(name: 'log_probs', kind: 'ctc', frameMs: 40, frames: 3, classes: 4,
          values: f32([-3, -0.1, -4, -5, -3, -0.2, -4, -5, -0.1, -3, -4, -5]));
      native.emit(ChunkUpdate(sessionId: id, chunk: chunkMessage(2, delta(ids: [1], frames: 3), heads: [lp])));
      final chunk = await got.future;
      final head = chunk.heads['log_probs']!;
      expect(head.kind, TajweedHeadKind.ctc);
      expect(head.at(1, 1), closeTo(-0.2, 1e-6));
      final greedy = chunk.heads.greedy();
      expect(greedy, hasLength(1));
      expect(greedy.single.name, 'a');
      expect(greedy.single.firstMs, 16 * 40); // chunk 2 starts at frame 16
      expect(greedy.single.lastMs, 17 * 40);
      expect(greedy.single.confidence, greaterThan(0.9));
      expect(chunk.heads.greedy('timing_log_probs'), isEmpty);
      expect(() => chunk.heads.greedy('gem'), throwsA(isA<TajweedError>()));
    });

    test('a reader that does not read keeps at most 256 chunks, never the last', () async {
      final (_, model) = await open();
      late int id;
      native.on('openSession', (args) => id = args[0] as int);
      final session = await model.session();
      for (var i = 0; i < 300; i++) {
        native.emit(ChunkUpdate(sessionId: id, chunk: chunkMessage(i, delta(frames: 1, frameStart: i))));
      }
      native.emit(ChunkUpdate(
          sessionId: id, chunk: chunkMessage(300, delta(frames: 1, frameStart: 300, isFinal: true))));
      native.emit(ClosedUpdate(sessionId: id));
      await Future<void>.delayed(Duration.zero);
      final all = await session.chunks.toList();
      expect(all, hasLength(256));
      expect(all.last.decoded.isFinal, isTrue);
      expect(all.first.index, 301 - 256);
      expect(session.droppedChunks, 301 - 256);
    });
  });

  group('data and sharing', () {
    test('the calibration is read as shipped', () async {
      native.on(
          'model',
          (_) => modelMessage(
              calibration: CalibrationMessage(
                  json: '{"format": "quranlab.tajweed-calibration/1", "classes": ["vowel_sub"], "presets": {"balanced": {}}, '
                      '"contexts": {"c16_l64": {"fusion": {"a": {"default": 0.5, "cons_sub": 0.7}}, '
                      '"sites": {"vowel_sub": {"status": "validated", "thresholds": {"balanced": 2}}}}}}',
                  sha256: 'ABCDEF')));
      final (_, model) = await open();
      final c = model.calibration!;
      expect(c.sha256, 'abcdef');
      expect(c.format, 'quranlab.tajweed-calibration/1');
      expect(c.presets, ['balanced']);
      expect(c.threshold('c16_l64', 'vowel_sub', 'balanced'), 2.0);
      expect(c.status('c16_l64', 'vowel_sub'), 'validated');
      expect(c.fusionWeight('c16_l64', 'cons_sub'), 0.7);
      expect(c.fusionWeight('c16_l64', 'vowel_sub'), 0.5);
      expect(c.value(['contexts', 'c16_l64', 'nothing']), isNull);
    });

    test('sharing: state, the learner switch, delete, theme and the settings screen go to the SDK', () async {
      native.on('sharingState', (_) => SharingStateMessage(available: true, on: false));
      native.on('sharingDelete', (_) => false);
      native.ok(['sharingSetOn', 'sharingSetTheme', 'sharingOpenSettings', 'sharingSetWording']);
      native.on('sharingAsk', (_) => true);
      final (client, _) = await open();
      expect(await client.sharing.isAvailable(), isTrue);
      expect(await client.sharing.isOn(), isFalse);
      expect(await client.sharing.recoveryCode(), isNull);
      await client.sharing.setOn(false);
      expect(native.calls.lastWhere((c) => c.$1 == 'sharingSetOn').$2, [false]);
      expect(await client.sharing.ask(), isTrue);
      expect(await client.sharing.delete(), isFalse);
      await client.sharing.setTheme(const SharingTheme(accent: 0xFF2A3B8F, cornerRadius: 20));
      final theme = native.calls.lastWhere((c) => c.$1 == 'sharingSetTheme').$2[0] as SharingThemeMessage;
      expect(theme.accent, 0xFF2A3B8F);
      expect(theme.cornerRadius, 20);
      expect(theme.background, isNull);
      await client.sharing.openSettings();
      expect(native.calls.map((c) => c.$1), contains('sharingOpenSettings'));
    });

    test('the app\'s own counts go to the SDK as given', () async {
      native.ok(['reportChecks']);
      final (client, model) = await open();
      await client.analytics.reportChecks('vowel_sub', checked: 31, flagged: 1);
      expect(native.calls.last.$2, ['vowel_sub', 31, 1]);
      final session = await model.session();
      await session.reportRecited(surah: 1, ayahFrom: 2, ayahTo: 2);
      expect(native.calls.last.$1, 'reportRecited');
      expect(native.calls.last.$2.sublist(1), [1, 2, 2, null, <Object?>[]]);
    });

    test('the judgement of a recited range goes with the report, per ayah too', () async {
      native.ok(['reportRecited']);
      final (_, model) = await open();
      final session = await model.session();
      await session.reportRecited(
          surah: 2,
          ayahFrom: 255,
          ayahTo: 257,
          outcome: TajweedRecitedOutcome.incorrect(mistakes: 2, rules: ['madd', 'qalqalah', 'madd']),
          perAyah: {255: const TajweedRecitedOutcome.correct()});
      final args = native.calls.last.$2;
      expect(args.sublist(1, 4), [2, 255, 257]);
      final outcome = args[4] as RecitedOutcomeMessage;
      expect(outcome.correct, isFalse);
      expect(outcome.mistakes, 2);
      expect(outcome.rules, ['madd', 'qalqalah']); // once each, as the native SDKs keep them
      expect(outcome.ayah, isNull);
      final per = (args[5] as List).cast<RecitedOutcomeMessage>().single;
      expect((per.ayah, per.correct, per.mistakes), (255, true, null));
      expect(per.rules, isEmpty);
    });

    test('an outcome the native SDKs would refuse is invalid_argument before any call', () {
      final bad = <TajweedRecitedOutcome Function()>[
        () => TajweedRecitedOutcome.incorrect(mistakes: 0),
        () => TajweedRecitedOutcome.incorrect(mistakes: 1001),
        () => TajweedRecitedOutcome.incorrect(rules: ['Madd']),
        () => TajweedRecitedOutcome.incorrect(rules: ['1madd']),
        () => TajweedRecitedOutcome.incorrect(rules: ['a' * 25]),
        () => TajweedRecitedOutcome.incorrect(rules: [for (var i = 0; i < 9; i++) 'r$i']),
      ];
      for (final make in bad) {
        expect(make, throwsA(isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.invalidArgument)));
      }
      expect(TajweedRecitedOutcome.incorrect(mistakes: 1000, rules: ['a' * 24]).rules, ['a' * 24]);
      expect(TajweedRecitedOutcome.incorrect(), TajweedRecitedOutcome.incorrect(mistakes: null, rules: const []));
      expect(const TajweedRecitedOutcome.correct().isCorrect, isTrue);
    });
  });

  /// Every name in the public library and everything under lib/, the channel's definition and both native sides,
  /// comments aside, that [banned] matches.
  List<String> namesMatching(RegExp banned) {
    final source = RegExp(r'\.(dart|kt|swift)$');
    final files = [
      for (final dir in ['lib', 'pigeon', 'android/src/main', 'ios'])
        ...Directory(dir).listSync(recursive: true).whereType<File>().where((f) => source.hasMatch(f.path)),
    ];
    expect(files.map((f) => f.uri.pathSegments.last),
        containsAll(['quranlab_tajweedformer.dart', 'client.dart', 'sharing.dart', 'messages.dart', 'Messages.g.kt',
            'TajweedFormerPlugin.kt', 'Messages.g.swift', 'TajweedFormerPlugin.swift']));
    final found = <String>[];
    for (final f in files) {
      final code = f.readAsLinesSync().map((l) => l.replaceFirst(RegExp(r'(^|\s)//.*$'), '')).join('\n');
      for (final m in RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').allMatches(code)) {
        if (banned.hasMatch(m[0]!)) found.add('${f.path}: ${m[0]}');
      }
    }
    return found;
  }

  test('no name of the plugin is audience, children or guardian: one sharing sheet for every app', () {
    expect(namesMatching(RegExp('audience|children|guardian', caseSensitive: false)), isEmpty);
  });

  group('nothing waits for Wi-Fi', () {
    test('no_wait_40 other_context_metered: prefetch() installs the default context, then a session on c24_l256; '
        'no network condition crosses the channel', () async {
      native.ok(['prefetch']);
      native.on('model', (_) => modelMessage()
        ..contexts = ['c16_l64', 'c8_l64', 'c24_l256']
        ..chunkMs = [320, 160, 480]);
      final client = await TajweedClient.create('qlk_v1_test');
      await client.prefetch();
      await client.prefetch(onProgress: (_, _) {});
      final model = await client.model();
      final session = await model.session(options: const TajweedSessionOptions(context: 'c24_l256'));
      // what the plugin asks of the native SDK, in order: prefetch carries its progress id and nothing else (4.0.1
      // sent unmeteredOnly first), and the session asks for c24_l256, whose files the native SDK downloads on
      // whatever network the device has (section 33.1; its own tests replay the case against a stand-in server)
      expect([for (final c in native.calls) c.$1], ['createClient', 'prefetch', 'prefetch', 'model', 'openSession']);
      expect(native.calls[1].$2, [null]);
      expect(native.calls[2].$2, hasLength(1));
      expect(native.calls[2].$2.single, isA<int>());
      final open = native.calls[4].$2;
      expect(open[1], 'push');
      expect((open[2]! as SessionOptionsMessage).context, 'c24_l256');
      await session.cancel();
    });

    test('no_wait_40 other_context_none: no network at all is needs_connection, its cause needs the model', () async {
      native.on('model', (_) => modelMessage()
        ..contexts = ['c16_l64', 'c8_l64', 'c24_l256']
        ..chunkMs = [320, 160, 480]);
      native.on('openSession', (_) => throw sdkError('needs_connection', 'm', 'f',
          cause: ErrorCauseMessage(stage: 'download', reason: 'network', needs: 'model')));
      final client = await TajweedClient.create('qlk_v1_test');
      final model = await client.model();
      final got = await model
          .session(options: const TajweedSessionOptions(context: 'c24_l256'))
          .then<Object>((s) => s, onError: (Object e) => e);
      expect(got, isA<TajweedError>().having((e) => e.code, 'code', TajweedErrorCode.needsConnection));
      expect((got as TajweedError).cause?.needs, TajweedErrorCause.needsModel);
      expect(got.cause?.stage, 'download');
    });

    test('no name of the plugin waits for a kind of network: no unmetered or Wi-Fi option', () {
      expect(namesMatching(RegExp('unmetered|wifi', caseSensitive: false)), isEmpty);
    });
  });

  test('every catalogue code is listed once', () {
    expect(TajweedErrorCode.all, hasLength(26));
    expect(TajweedErrorCode.all.toSet(), hasLength(26));
    expect(TajweedError.from(PlatformException(code: 'needs_connection', message: 'offline')).code, 'needs_connection');
  });

  group('ERRORS_40', () {
    // the code and cause rows of quranlab-contract sdk_4.0.0/vectors/errors_40.json at adca6f6 (SDK 4.0.2); its
    // `from` names the full file's SHA-256 and the one row left out
    final vectors = jsonDecode(File('test/fixtures/errors_40.json').readAsStringSync()) as Map<String, Object?>;
    final cases = (vectors['codes'] as List).cast<Map<String, Object?>>();
    final causes = (vectors['causes'] as List).cast<Map<String, Object?>>();

    test('the code cases name catalogue codes only, and the unreported five are the API-misuse ones', () {
      expect(cases, hasLength(73));
      for (final c in cases) {
        final code = c['code'] as String;
        if (code != 'none') expect(TajweedErrorCode.all, contains(code), reason: '$c');
      }
      expect(vectors['codes_not_reported'], [
        TajweedErrorCode.invalidArgument, TajweedErrorCode.clientExists, TajweedErrorCode.sessionOpen,
        TajweedErrorCode.sessionClosed, TajweedErrorCode.cancelled,
      ]);
    });

    test('each case reaches Dart one to one: the native code as the TajweedError code, or no error for a silent one',
        () async {
      for (final c in cases) {
        final code = c['code'] as String;
        native.on('model', (_) {
          if (code == 'none') return modelMessage(); // a silent report: the app's call goes on
          throw sdkError(code, 'The native message (${c['stage']}, ${c['reason']}).', 'The native fix.');
        });
        final client = await TajweedClient.create('qlk_v1_test');
        final got = await client.model().then<Object>((m) => m, onError: (Object e) => e);
        if (code == 'none') {
          expect(got, isA<TajweedModel>(), reason: '$c');
        } else {
          expect(got, isA<TajweedError>(), reason: '$c');
          final e = got as TajweedError;
          expect(e.code, code, reason: '$c');
          expect(e.message, 'The native message (${c['stage']}, ${c['reason']}).');
          expect(e.fix, 'The native fix.');
          expect(e.docs, 'https://sdk.quranlab.ai/docs/errors#$code');
        }
        await client.close();
      }
    });

    test('24.13: each cause row reaches Dart as the native error carries it, on a call and at the end of a take',
        () async {
      expect(causes, hasLength(14));
      for (final c in causes) {
        final code = c['code'] as String;
        final want = c['cause'] as Map<String, Object?>?;
        final cause = want == null
            ? null
            : TajweedErrorCause(
                stage: want['stage']! as String,
                reason: want['reason']! as String,
                httpStatus: want['http_status'] as int?,
                errorName: want['error_name'] as String?,
                errorCode: want['error_code'] as String?,
                needs: want['needs'] as String?);
        if (code == 'needs_connection') {
          final needs = c['on_device'] == 'complete' ? TajweedErrorCause.needsLease : TajweedErrorCause.needsModel;
          expect(cause?.needs, needs, reason: '${c['label']}');
        } else {
          expect(cause?.needs, isNull, reason: '${c['label']}');
        }
        native.on('model', (_) {
          if (code == 'none') return modelMessage(); // a silent failure makes no error
          throw sdkError(code, 'The native message.', 'The native fix.', cause: causeMessage(want));
        });
        final client = await TajweedClient.create('qlk_v1_test');
        final got = await client.model().then<Object>((m) => m, onError: (Object e) => e);
        if (code == 'none') {
          expect(got, isA<TajweedModel>(), reason: '${c['label']}');
          await client.close();
          continue;
        }
        expect(got, isA<TajweedError>().having((e) => e.code, 'code', code).having((e) => e.cause, 'cause', cause),
            reason: '${c['label']}');
        // the same error ending a take (TajweedEnded), through the update channel
        native.on('model', (_) => modelMessage());
        final model = await client.model();
        late int id;
        native.on('openSession', (args) => id = args[0] as int);
        final session = await model.session();
        final ended = session.events.firstWhere((e) => e is TajweedEnded);
        native.emit(EventUpdate(
            sessionId: id,
            event: EventMessage(
                type: 'ended',
                reason: 'error',
                error: ErrorMessage(
                    code: code, message: 'm', fix: 'f', docs: 'd', cause: causeMessage(want)))));
        native.emit(ClosedUpdate(sessionId: id));
        final end = await ended as TajweedEnded;
        expect(end.error?.code, code);
        expect(end.error?.cause, cause, reason: '${c['label']}');
        await client.close();
      }
    });

    test('24.13: needs_connection with needs model, with needs lease, and an error with no cause', () async {
      Future<TajweedError> fail(PlatformException e) async {
        native.on('model', (_) => throw e);
        final client = await TajweedClient.create('qlk_v1_test');
        final got = await client.model().then<Object>((m) => m, onError: (Object e) => e);
        await client.close();
        return got as TajweedError;
      }

      final model = await fail(sdkError('needs_connection', 'm', 'f',
          cause: ErrorCauseMessage(stage: 'download', reason: 'network', errorName: 'java.net.UnknownHostException',
              needs: 'model')));
      expect(model.code, TajweedErrorCode.needsConnection);
      expect(model.cause, const TajweedErrorCause(
          stage: 'download', reason: 'network', errorName: 'java.net.UnknownHostException', needs: 'model'));
      expect(model.cause!.needs, TajweedErrorCause.needsModel);
      expect(model.cause!.httpStatus, isNull);
      expect(model.cause.toString(), 'TajweedErrorCause(stage: download, reason: network, '
          'errorName: java.net.UnknownHostException, needs: model)');

      final lease = await fail(sdkError('needs_connection', 'm', 'f',
          cause: ErrorCauseMessage(stage: 'lease', reason: 'network', errorName: 'NSURLErrorDomain', errorCode: '-1001',
              needs: 'lease')));
      expect(lease.cause!.needs, TajweedErrorCause.needsLease);
      expect(lease.cause!.stage, 'lease');
      expect(lease.cause!.errorCode, '-1001');
      expect(lease, isNot(model));

      final limit = await fail(sdkError('download_failed', 'm', 'f',
          cause: ErrorCauseMessage(
              stage: 'download', reason: 'rate_limited', httpStatus: 429, errorCode: 'model_limit')));
      expect(limit.cause!.httpStatus, 429);
      expect(limit.cause!.needs, isNull);

      // the five API-misuse codes carry none (null in its place), nor do the plugin's own errors ([fix, docs])
      final none = await fail(sdkError('session_open', 'm', 'f'));
      expect(none.code, TajweedErrorCode.sessionOpen);
      expect(none.cause, isNull);
      final own = await fail(PlatformException(code: 'invalid_argument', message: 'm',
          details: ['f', 'https://sdk.quranlab.ai/docs/errors#invalid_argument']));
      expect(own.cause, isNull);
      expect(own.fix, 'f');
    });
  });
}
