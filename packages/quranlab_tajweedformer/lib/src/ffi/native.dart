// The C SDK (tajweedformer.dll / libtajweedformer.so) as Dart: its libraries, its errors and its output read into the
// messages every platform sends (pigeon/messages.dart). Used by the main isolate and the engine isolate alike; each
// opens the libraries itself. Internal.
//
// The C SDK's rules this follows (tajweedformer.h): a failure is the calling THREAD's last error, so it is read in
// the same synchronous run as the failing call; strings it returns belong to the object and live until the next
// call on it, so they are copied at once; a Model and its Session are used from one thread at a time (the engine
// isolate's).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../delta.dart';
import '../errors.dart';
import '../messages.g.dart';
import 'tajweedformer.g.dart';

/// The libraries of one isolate.
class TfNative {
  TfNative._(this.tf, this._get, this._set);

  /// Tests: bindings to a stand-in of the C SDK, and the slots of the plugin's library as two functions.
  @visibleForTesting
  TfNative.forTest(this.tf, int Function(int slot) get, int Function(int slot, int value) set)
      : _get = get,
        _set = set;

  static TfNative? _open;

  /// The C SDK and the plugin's own small library, opened once per isolate. [dir]: the folder they are in (tests);
  /// null: the app's own (beside the program on Windows, its `lib` folder on Linux).
  static TfNative open([String? dir]) {
    final o = _open;
    if (o != null) return o;
    String path(String name) => dir == null ? name : '$dir${Platform.pathSeparator}$name';
    final DynamicLibrary sdk, shim;
    try {
      sdk = DynamicLibrary.open(path(Platform.isWindows ? 'tajweedformer.dll' : 'libtajweedformer.so'));
      shim = DynamicLibrary.open(
          path(Platform.isWindows ? 'quranlab_tajweedformer_shim.dll' : 'libquranlab_tajweedformer_shim.so'));
    } on ArgumentError catch (e) {
      throw TajweedError(TajweedErrorCode.runtimeUnsupported,
          'The TajweedFormer C SDK could not be loaded: ${e.message}',
          fix: 'Build the app with flutter build (the plugin bundles the C SDK and the Core beside the program); the '
              'C SDK runs on Windows and Linux on x86-64.');
    }
    return _open = TfNative._(
      TfBindings(sdk),
      shim.lookupFunction<IntPtr Function(Int32), int Function(int)>('qltf_get'),
      shim.lookupFunction<IntPtr Function(Int32, IntPtr), int Function(int, int)>('qltf_set'),
    );
  }

  final TfBindings tf;
  final int Function(int slot) _get;
  final int Function(int slot, int value) _set;

  // ---- what survives a hot restart (src/quranlab_tajweedformer_shim.h) ----

  static const slotClient = 0, slotModel = 1, slotSession = 2, slotKey = 3;

  int slot(int s) => _get(s);
  int setSlot(int s, int value) => _set(s, value);

  // ---- errors ----

  /// This thread's last failure as the SDK's error: its code, message, fix, docs and cause. Call it right after the
  /// failing call, with no await between.
  TajweedError lastError({String? fallbackCode}) {
    final code = tf.tf_last_error_code();
    if (code == 0) {
      final c = fallbackCode ?? TajweedErrorCode.engineFailed;
      return TajweedError(c, 'The C SDK failed without an error ($c).', fix: 'Send client.diagnose() with an issue to Quran Lab.');
    }
    final name = str(tf.tf_error_name(code)) ?? TajweedErrorCode.engineFailed;
    final message = str(tf.tf_last_error()) ?? name;
    final fix = str(tf.tf_last_error_fix()) ?? str(tf.tf_error_fix(code)) ?? '';
    final docs = str(tf.tf_error_docs(code));
    TajweedErrorCause? cause;
    final p = calloc<TfErrorCause>();
    try {
      if (tf.tf_last_error_cause(p) == 1) {
        final c = p.ref;
        cause = TajweedErrorCause(
          stage: str(c.stage) ?? 'other',
          reason: str(c.reason) ?? 'other',
          httpStatus: c.http_status == 0 ? null : c.http_status,
          errorName: str(c.error_name),
          errorCode: str(c.error_code),
          needs: str(c.needs),
        );
      }
    } finally {
      calloc.free(p);
    }
    return TajweedError(name, message, fix: fix, docs: docs, cause: cause);
  }

  /// The catalogue's error of a code, for an error that comes as a number (a take that ended with one).
  ErrorMessage errorMessage(int code, {String? message}) {
    final name = str(tf.tf_error_name(code)) ?? TajweedErrorCode.engineFailed;
    return ErrorMessage(
      code: name,
      message: message ?? 'The take ended with $name.',
      fix: str(tf.tf_error_fix(code)) ?? '',
      docs: str(tf.tf_error_docs(code)) ?? 'https://sdk.quranlab.ai/docs/errors#$name',
    );
  }

  /// Fails with the SDK's error when [rc] is negative.
  int check(int rc) {
    if (rc < 0) throw lastError();
    return rc;
  }

  /// Fails with the SDK's error when [p] is NULL.
  Pointer<T> checkPtr<T extends NativeType>(Pointer<T> p) {
    if (p == nullptr) throw lastError();
    return p;
  }

  // ---- the output ----

  BackendMessage backend(TfBackend b) => BackendMessage(
        kind: str(b.kind) ?? 'cpu',
        name: str(b.name) ?? 'cpu',
        stage: str(b.stage) ?? 'cpu',
        reason: str(b.reason),
      );

  /// Every head the Heads hold, in the network's order, its values copied.
  List<HeadMessage> heads(Pointer<TfHeads> h) {
    if (h == nullptr) return const [];
    final out = <HeadMessage>[];
    final head = calloc<TfHead>();
    try {
      final n = tf.tf_heads_count(h);
      for (var i = 0; i < n; i++) {
        final name = tf.tf_heads_name(h, i);
        if (name == nullptr || tf.tf_heads_get(h, name, head) < 0) continue;
        final r = head.ref;
        final count = r.frames * r.classes;
        final values = count == 0 || r.values == nullptr
            ? Uint8List(0)
            : Uint8List.fromList(r.values.cast<Uint8>().asTypedList(count * 4));
        List<String>? classNames;
        if (r.class_names != nullptr) {
          classNames = [for (var k = 0; k < r.classes; k++) str(r.class_names[k]) ?? ''];
        }
        out.add(HeadMessage(
          name: name.cast<Utf8>().toDartString(),
          kind: str(r.kind) ?? 'attribute',
          frameMs: r.frame_ms,
          frames: r.frames,
          classes: r.classes,
          values: values,
          classNames: classNames,
        ));
      }
    } finally {
      calloc.free(head);
    }
    return out;
  }

  /// A decoded layer as the delta encoder reads it. Valid while the layer is (the chunk's callback, or the Heads).
  DecodedRows decoded(Pointer<TfDecoded> p) {
    final d = p.ref;
    final tokens = <TokenRow>[
      for (var i = 0; i < d.n_tokens; i++)
        TokenRow(d.tokens[i].id, d.tokens[i].first_ms, d.tokens[i].peak_ms, d.tokens[i].last_ms, d.tokens[i].confidence),
    ];
    final frames = d.frames;
    final k = d.top_k;
    final ids = d.ranked_ids, lps = d.ranked_log_probs;
    return DecodedRows(
      tokens: tokens,
      frameCount: d.n_frames,
      frame: (f) {
        final r = frames[f];
        return (r.top1, r.top1_log_prob, r.runner_up, r.runner_up_log_prob, r.margin);
      },
      rankedK: k > 0 && ids != nullptr && lps != nullptr ? k : 0,
      ranked: (f, j) => (ids[f * k + j], lps[f * k + j]),
      settled: d.settled,
      isFinal: d.is_final != 0,
    );
  }

  /// One event of a take as the message every platform sends.
  EventMessage event(TfEvent e) {
    final name = str(e.name);
    switch (e.type) {
      case TF_EVENT_SPEECH_STARTED:
        return EventMessage(type: 'speechStarted', atMs: e.at_ms);
      case TF_EVENT_SPEECH_ENDED:
        return EventMessage(type: 'speechEnded', atMs: e.at_ms, silenceMs: e.silence_ms);
      case TF_EVENT_ENDED:
        final reason = switch (e.reason) {
          TF_ENDED_SILENCE => 'silence',
          TF_ENDED_BACKGROUND => 'background',
          TF_ENDED_HIDDEN => 'hidden',
          TF_ENDED_INTERRUPTED => 'interrupted',
          TF_ENDED_SOURCE_END => 'sourceEnd',
          TF_ENDED_LIMIT => 'limit',
          _ => 'error',
        };
        return EventMessage(
            type: 'ended', reason: reason, error: reason == 'error' ? errorMessage(e.error == 0 ? -22 : e.error) : null);
      default:
        // never raised by the C SDK (interrupted, resumed, backendChanged): its own name
        return EventMessage(type: name ?? 'resumed');
    }
  }
}

/// A C string as Dart, or null for NULL.
String? str(Pointer<Char> p) => p == nullptr ? null : p.cast<Utf8>().toDartString();

/// A C string that must be there.
String strOr(Pointer<Char> p, String fallback) => str(p) ?? fallback;

/// JSON from the C SDK, or null.
Object? jsonOf(Pointer<Char> p) => jsonOfString(str(p));

/// JSON text as Dart, or null.
Object? jsonOfString(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}

/// Pushed bytes (float32 or signed 16-bit, little endian) as float samples in native memory; the caller frees it.
Pointer<Float> samplesOf(Uint8List pcm, bool int16) {
  final data = ByteData.sublistView(pcm);
  final n = int16 ? pcm.lengthInBytes ~/ 2 : pcm.lengthInBytes ~/ 4;
  final p = calloc<Float>(n == 0 ? 1 : n);
  final out = p.asTypedList(n);
  if (int16) {
    for (var i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
  } else {
    for (var i = 0; i < n; i++) {
      out[i] = data.getFloat32(i * 4, Endian.little);
    }
  }
  return p;
}

/// The number of samples in pushed bytes.
int sampleCount(Uint8List pcm, bool int16) => int16 ? pcm.lengthInBytes ~/ 2 : pcm.lengthInBytes ~/ 4;
