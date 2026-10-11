import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'clip_tokenizer.dart';
import 'clip_vision.dart';
import 'index_worker.dart';
import 'media_source.dart';
import 'mlkit_labels.dart';
import 'mlkit_ocr.dart';
import 'search_service.dart';

/// Crash fuse for native model loads (Step 5 hardening).
///
/// Lesson learned the hard way: a SIGSEGV-class load failure kills the
/// process before SharedPreferences' async flush runs, so a prefs-backed
/// counter NEVER advances (observed stuck at 0 across three deaths) and
/// the app boot-loops. This file is written synchronously + fsync'd, so
/// the increment survives even a death microseconds later.
class ClipFuse {
  static const fileName = 'clip_fuse.txt';

  static File _file(String docsPath) => File('$docsPath/$fileName');

  static Future<int> read(String docsPath) async {
    try {
      return int.parse((await _file(docsPath).readAsString()).trim());
    } catch (_) {
      return 0;
    }
  }

  static void writeSync(String docsPath, int n) {
    try {
      final f = _file(docsPath).openSync(mode: FileMode.write);
      try {
        f.writeStringSync('$n');
        f.flushSync();
      } finally {
        f.closeSync();
      }
    } catch (_) {}
  }
}

/// CLIP joint image+text tower (Step 5).
///
/// Loads `clip_joint_s2.tflite` (378MB — adb-pushed, never bundled) from the
/// app sandbox plus the bundled `vocab.json`/`merges.txt` pair, then serves
/// both directions: text queries and photo pixels become the same 512-d
/// INT8-quantized space the DB already stores (0-255, zero-point 128).
///
/// Everything fallible is fail-closed: [load] returns false (caller keeps
/// the stub), per-file errors throw to the worker's per-file capture.
/// Output-head assignment (which of the two 512-d outputs is text) is
/// auto-resolved at load by varying the text input; [resolvedByProbe]
/// reports how. Device confirms via the Model status row.
class ClipJoint {
  /// Clean MIT-licensed joint tower (Option B): LAION ViT-B/32 converted
  /// in-house (tools/export_joint_onnx.py + convert_onnx_to_tflite.py).
  /// Same joint layout as before (preprocessed image + 77 token ids in,
  /// two 512-d embeddings + scale out); image size is 224 (B/32 native).
  /// The retired Apple-weights file (clip_joint_s2.tflite) is ignored.
  static const fileName = 'clip_joint_b32_int8.tflite';

  /// ViT-B/32 native input resolution (was 256 for MobileCLIP-S2).
  static const imageSize = 224;
  static const dim = 512;

  /// Single-threaded until the Transsion XNNPACK question is settled on
  /// device (the joint graph segfaulted a 4-thread load attempt; debug
  /// with threads=1 first, raise only with timing proof in hand).
  static const threads = 1;

  Interpreter? _interp;
  ClipTokenizer? _tokenizer;

  /// Output head indices: text tower output / image tower output.
  int textOut = 1;
  int imageOut = 0;
  bool resolvedByProbe = false;

  String? lastError;
  String tensorInfo = '';
  double lastMillis = -1;

  bool get isLoaded => _interp != null && _tokenizer != null;

  /// Locate the model file across the adb-push debug paths.
  static Future<File?> findModelFile() async {
    final tried = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      final a = File('${docs.path}/models/$fileName');
      tried.add(a.path);
      if (await a.exists()) return a;
    } catch (_) {}
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final b = File('${ext.path}/models/$fileName');
        tried.add(b.path);
        if (await b.exists()) return b;
      }
    } catch (_) {}
    _triedPaths = tried;
    return null;
  }

  static List<String> _triedPaths = [];
  static List<String> get triedPaths => _triedPaths;

  Future<bool> load() => loadStaged(runProbe: true);

  /// Staged load for segfault bisection (see AppIndex fuse notes).
  /// [runProbe]=false maps the model + reads tensor metadata but never
  /// invokes it: surviving this stage proves the killer is inference
  /// (XNNPACK/ops), dying here proves it is load/mmap/graph-build.
  Future<bool> loadStaged({required bool runProbe}) async {
    try {
      final file = await findModelFile();
      if (file == null) {
        lastError = 'model file missing (tried: ${triedPaths.join(', ')})';
        return false;
      }
      _tokenizer = await ClipTokenizer.loadDefault();
      final options = InterpreterOptions()..threads = threads;
      _interp = Interpreter.fromFile(file, options: options);
      final inT = _interp!.getInputTensors();
      final outT = _interp!.getOutputTensors();
      tensorInfo =
          'in=${inT.map((t) => '${t.shape}:${t.type}').join(' ')} '
          'out=${outT.map((t) => '${t.shape}:${t.type}').join(' ')}';
      if (runProbe) await _resolveOutputs();
      return true;
    } catch (e) {
      lastError = '$e';
      _interp = null;
      return false;
    }
  }

  /// Vary only the text input across two runs: the output head that moves
  /// is the text tower. Falls back to text=1/image=0 (unresolved).
  Future<void> _resolveOutputs() async {
    try {
      final tok = _tokenizer!;
      final zeros = Float32List(3 * imageSize * imageSize);
      final a = await _raw(zeros, tok.encode('sunset over the ocean'));
      final b = await _raw(zeros, tok.encode('receipt grocery store total'));
      var best = -1.0;
      var bestIdx = 1;
      for (var i = 0; i < 2; i++) {
        var dist = 0.0;
        for (var j = 0; j < dim; j++) {
          final d = a[i][j] - b[i][j];
          dist += d * d;
        }
        if (dist > best) {
          best = dist;
          bestIdx = i;
        }
      }
      if (best > 1e-12) {
        textOut = bestIdx;
        imageOut = 1 - bestIdx;
        resolvedByProbe = true;
      }
    } catch (_) {
      // Keep defaults; surfaced as unresolved in diagnostics.
    }
  }

  /// Channel-first [3][n][n] frontend output -> interleaved [H,W,3].
  /// Pure — unit-tested (the TFLite file is NHWC; feeding NCHW bytes
  /// under an NHWC shape silently scrambles every image).
  static Float32List nchwToNhwc(Float32List nchw, int size) {
    final n = size * size;
    final hwc = Float32List(3 * n);
    for (var i = 0; i < n; i++) {
      hwc[i * 3] = nchw[i];
      hwc[i * 3 + 1] = nchw[n + i];
      hwc[i * 3 + 2] = nchw[2 * n + i];
    }
    return hwc;
  }

  /// Raw joint run. Returns the two 512-d float outputs (+ ignores scalar).
  /// Int32 throughout (int64 graph inputs are rejected by TFLite builds);
  /// the EOT index rides as the third input (no ArgMax in the graph).
  Future<List<List<double>>> _raw(
    Float32List imageNchw,
    List<int> tokenIds,
  ) async {
    final interp = _interp!;
    final sw = Stopwatch()..start();
    final imageInput = nchwToNhwc(imageNchw, imageSize).reshape(
      [1, imageSize, imageSize, 3],
    );
    final tokenInput = Int32List.fromList(tokenIds).reshape([1, 77]);
    final eotInput =
        Int32List.fromList([ClipTokenizer.eotPosition(tokenIds)])
            .reshape([1]);
    final out0 = List.filled(dim, 0.0).reshape([1, dim]);
    final out1 = List.filled(dim, 0.0).reshape([1, dim]);
    final outScalar = Float32List(1);
    interp.runForMultipleInputs(
      [imageInput, tokenInput, eotInput],
      {0: out0, 1: out1, 2: outScalar},
    );
    sw.stop();
    lastMillis = sw.elapsedMicroseconds / 1000.0;
    return [
      List<double>.from(out0[0] as List),
      List<double>.from(out1[0] as List),
    ];
  }

  /// Text query -> quantized 512-d (0-255), matching [TextEmbedder].
  Future<List<int>> embedText(String query) async {
    final tok = _tokenizer!;
    final zeros = Float32List(3 * imageSize * imageSize);
    final outs = await _raw(zeros, tok.encode(query));
    return quantize(_normalize(outs[textOut]));
  }

  /// Photo bytes -> quantized 512-d for [insertIndexed]. Throws on
  /// undecodable bytes (worker's per-file capture records it).
  Future<List<int>> embedImage(Uint8List bytes) async {
    final pixels = ClipVision.preprocess(bytes);
    if (pixels == null) throw StateError('undecodable image bytes');
    final tok = _tokenizer!;
    final outs = await _raw(pixels, tok.encode(''));
    return quantize(_normalize(outs[imageOut]));
  }

  static List<double> _normalize(List<double> v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm < 1e-12) return v;
    return [for (final x in v) x / norm];
  }

  /// L2-normalized [-1,1] floats -> INT8-style 0-255 (zero-point 128),
  /// the exact convention [IndexDatabase.cosineInt8] expects.
  static List<int> quantize(List<double> v) {
    return [
      for (final x in v) ((x * 127 + 128).round()).clamp(0, 255),
    ];
  }
}

/// Query-side adapter: real CLIP text tower behind [TextEmbedder]
/// (512-d quantized). Falls back to the stub wherever [AppIndex] decides.
class ClipTextEmbedder implements TextEmbedder {
  final ClipJoint joint;
  const ClipTextEmbedder(this.joint);

  @override
  int get dimension => ClipJoint.dim;

  @override
  Future<List<int>> embed(String query) => joint.embedText(query);
}

/// Index-side adapter: real CLIP image tower behind [FeatureExtractor].
/// Hybrid vigor: the 512-d vector carries meaning ("describe in your own
/// words"), while ML Kit label words ride along as ocrText so exact-keyword
/// queries ("receipt") and the home chips keep working. Photos embed full
/// bytes; videos embed the OS-cached thumbnail (one inference per video —
/// no frame-decode battery cost) plus thumbnail labels, so videos are
/// searchable by both looks and words. Anything unresolvable throws to the
/// worker's per-file capture (photo bytes) or degrades to a zero vector
/// with whatever labels survived (missing thumbnail — visual gate drops it,
/// text still matches).
class ClipImageExtractor implements FeatureExtractor {
  final ClipJoint joint;
  final LabelBackend backend;
  final OcrBackend ocr;
  const ClipImageExtractor(
    this.joint, {
    this.backend = const MlKitLabelBackend(),
    this.ocr = const MlKitOcrBackend(),
  });

  @override
  String get modelVersion => 'clip-b32-int8';

  /// Zero 512-d vector (all 128s): cosineInt8 vs anything is ~0, so the
  /// visual gate drops it while text matches survive.
  static List<int> get zeroVector => List<int>.filled(ClipJoint.dim, 128);

  @override
  Future<IndexFeatures> extract(MediaEntry entry) async {
    final id = photoAssetIdFromUri(entry.uri);
    if (id == null) {
      throw StateError('clip image tower needs a photo asset id');
    }
    if (entry.isVideo) {
      return _extractVideo(id);
    }
    final asset = await AssetEntity.fromId(id);
    final bytes = await asset?.originBytes;
    if (bytes == null) throw StateError('asset bytes unavailable: $id');
    var path = '';
    try {
      path = (await asset?.file)?.path ?? '';
    } catch (_) {}
    var labels = '';
    if (path.isNotEmpty) {
      try {
        labels = await backend.labelFile(path);
      } catch (_) {}
    }
    final words = path.isEmpty
        ? ''
        : await MlKitOcr(backend: ocr).readWords(path);
    final text = words.isEmpty ? labels : '$labels $words';
    return IndexFeatures(
      vector: Uint8List.fromList(await joint.embedImage(bytes)),
      ocrText: text.trim(),
    );
  }

  Future<IndexFeatures> _extractVideo(String id) async {
    AssetEntity? asset;
    try {
      asset = await AssetEntity.fromId(id);
    } catch (_) {
      asset = null;
    }
    final thumb = await MlKitPhotoExtractor.videoThumbnailBytes(asset);
    final labels = thumb == null
        ? ''
        : await MlKitPhotoExtractor.describeJpegBytes(thumb, backend, ocr);
    List<int> vec;
    try {
      vec = thumb == null ? zeroVector : await joint.embedImage(thumb);
    } catch (_) {
      vec = zeroVector;
    }
    return IndexFeatures(
      vector: Uint8List.fromList(vec),
      ocrText: labels,
    );
  }
}
