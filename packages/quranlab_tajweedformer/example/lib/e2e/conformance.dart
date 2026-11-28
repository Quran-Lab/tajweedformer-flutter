// The release check every platform runs: the 35 conformance clips through the plugin on the CPU engine, every head
// of every chunk against the Core gate's FNV-1a, as Android's, iOS's, the C SDK's and the web SDK's release checks do.
// No dart:io here: the web run reads its inputs over HTTP, the others from files; each passes its own reader.
//
//   expected.jsonl   the Core gate's file (conformance/v4_c16_l64_audio_expected.jsonl): per clip its greedy tokens
//                    and the FNV-1a of every head of every chunk
//   <clip>.pcm       its clips, 16 kHz mono float32 little endian
import 'dart:convert';
import 'dart:typed_data';

import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

/// FNV-1a 64 in four 16-bit limbs, so that it gives the same bits on the web (whose integers are doubles) as on the
/// Dart VM.
class Fnv64 {
  /// [basis]: the 16 hex digits to start from.
  Fnv64(String basis)
      : _l = [
          int.parse(basis.substring(12, 16), radix: 16),
          int.parse(basis.substring(8, 12), radix: 16),
          int.parse(basis.substring(4, 8), radix: 16),
          int.parse(basis.substring(0, 4), radix: 16),
        ];

  /// The standard offset basis.
  static const standard = 'cbf29ce484222325';

  /// The Core's conformance tools (qlc_bench.c, zf_test.h) start at 1469598103934665603: the standard basis with its
  /// last decimal digit dropped. The gate file's per-chunk values and `logp_fnv` were made with it.
  static const gate = '14650fb0739d0383';

  final List<int> _l;

  void add(Uint8List bytes) {
    var a = _l[0], b = _l[1], c = _l[2], d = _l[3];
    for (final x in bytes) {
      a ^= x;
      // h * 0x100000001b3 = h * 0x1b3 + (h << 40), mod 2^64
      final m0 = a * 0x1b3, m1 = b * 0x1b3 + (m0 >> 16), m2 = c * 0x1b3 + (m1 >> 16), m3 = d * 0x1b3 + (m2 >> 16);
      // h << 40: limb 0 moves to bits 40..55 (limbs 2 and 3 at an 8-bit offset), limb 1 to 56..71
      final s2 = (a << 8) & 0xffff, s3 = ((a >> 8) & 0xff) | ((b << 8) & 0xff00);
      final n2 = (m2 & 0xffff) + s2;
      a = m0 & 0xffff;
      b = m1 & 0xffff;
      c = n2 & 0xffff;
      d = ((m3 & 0xffff) + s3 + (n2 >> 16)) & 0xffff;
    }
    _l
      ..[0] = a
      ..[1] = b
      ..[2] = c
      ..[3] = d;
  }

  String get hex => [for (final x in _l.reversed) x.toRadixString(16).padLeft(4, '0')].join();
}

String fnvHex(String basis, Uint8List bytes) => (Fnv64(basis)..add(bytes)).hex;

Uint8List bytesOf(Float32List v) => v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);

/// The gate file's lines.
List<Map<String, Object?>> expectedOf(String text) => [
      for (final line in const LineSplitter().convert(text))
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];

/// Runs the clips of [expected] through [model] (each read by [clip]) and returns the report: `clips`, `identical`
/// (chunk count, `logp_fnv` and every head's per-chunk FNV equal), `tokens_same` (greedy tokens equal), `chunks`,
/// `digest` and `gate_digest` (one FNV over every value, ours and the gate's, which must be equal), `ms`, `bad`.
Future<Map<String, Object?>> conformance(
    TajweedModel model, List<Map<String, Object?>> expected, Future<Float32List> Function(String clip) clip) async {
  final heads12 = [...TajweedSessionOptions.allHeads]..sort();
  var identical = 0, tokensSame = 0, chunksAll = 0;
  final digest = Fnv64(Fnv64.standard), gateDigest = Fnv64(Fnv64.standard);
  final bad = <String>[];
  final started = DateTime.now();
  for (final e in expected) {
    final name = e['clip'] as String;
    final samples = await clip(name);
    final session = await model.listenFromSamples(samples, 16000,
        options: const TajweedSessionOptions(
            context: 'c16_l64', heads: TajweedSessionOptions.allHeads, backend: TajweedSessionBackend.cpu, pace: TajweedPace.fast));
    final chunks = await session.chunks.toList();
    final heads = await session.finish();
    chunksAll += chunks.length;
    final want = [for (final t in e['tokens'] as List) (t as num).toInt()];
    final got = [for (final t in heads.greedy()) t.id];
    if (got.length == want.length && Iterable<int>.generate(got.length).every((i) => got[i] == want[i])) tokensSame++;
    final out = (e['out_fnv'] as Map).cast<String, List<Object?>>();
    final fnvs = <String, List<String>>{};
    final logp = Fnv64(Fnv64.gate);
    for (final c in chunks) {
      for (final h in heads12) {
        final v = c.heads[h]?.values;
        (fnvs[h] ??= []).add(v == null ? '0000000000000000' : fnvHex(Fnv64.gate, bytesOf(v)));
        if (h == 'log_probs' && v != null) logp.add(bytesOf(v));
      }
    }
    // one digest over every output of every chunk, in the gate file's order, the same way for the gate's own values
    for (final h in heads12) {
      for (final x in fnvs[h] ?? const <String>[]) {
        digest.add(Uint8List.fromList(utf8.encode(x)));
      }
      for (final x in out[h] ?? const []) {
        gateDigest.add(Uint8List.fromList(utf8.encode(x as String)));
      }
    }
    final sameHeads = heads12.every((h) {
      final a = fnvs[h] ?? const <String>[];
      final b = out[h] ?? const [];
      return a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
    });
    final same = chunks.length == (e['chunks'] as num).toInt() && logp.hex == e['logp_fnv'] && sameHeads;
    if (same) {
      identical++;
    } else {
      bad.add('$name chunks ${chunks.length}/${e['chunks']} logp ${logp.hex == e['logp_fnv']} '
          'heads ${heads12.where((h) => '${fnvs[h]}' != '${out[h]}').toList()}');
    }
  }
  return {
    'clips': expected.length,
    'identical': identical,
    'tokens_same': tokensSame,
    'chunks': chunksAll,
    'digest': digest.hex,
    'gate_digest': gateDigest.hex,
    'ms': DateTime.now().difference(started).inMilliseconds,
    'bad': bad.take(6).toList(),
  };
}

/// What the open step reports: the model, the lease and the servers, from `diagnose()` (no key, no identifier).
Future<Map<String, Object?>> openReport(TajweedClient client, TajweedModel model, int ms, int done, int total) async {
  final d = await client.diagnose();
  final storage = await client.storage();
  return {
    'ms': ms,
    'download_done': done,
    'download_total': total,
    'model': model.version,
    'build': model.build,
    'contexts': model.contexts,
    'backend': '${await model.backend()}',
    'sdk': d.sdkVersion,
    'key_accepted': d.keyAccepted,
    'config': d.config,
    'model_verified': d.modelVerified,
    'protected': {
      'keyStore': d.protectedModel?.keyStore,
      'lease': d.protectedModel?.lease,
      'leaseClass': d.protectedModel?.leaseClass,
      'core': d.protectedModel?.core,
    },
    'stored': [for (final m in storage.models) '${m.version} ${m.build} ${m.bytes}'],
  };
}
