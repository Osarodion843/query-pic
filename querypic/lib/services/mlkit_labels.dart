import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import 'index_worker.dart';
import 'media_source.dart';
import 'mlkit_ocr.dart';
import 'stub_embed.dart';

/// On-device photo understanding without the 378MB CLIP file (Step 5B).
///
/// Google ML Kit's image labeler names what's in each photo (`beach`,
/// `receipt`, `dog`, …) on-device, and the text recognizer reads words
/// printed inside the image; both land in the FTS-indexed OCR text column,
/// so plain words match real photo contents — and words visible in the
/// photo ("following" on a poster) — with the normal confidence pipeline.
/// v2 also labeled each video's OS-cached thumbnail; v3 adds OCR on top.
/// Vectors stay URI-derived stubs (visual scores are noise until a real
/// embedding tower lands) — text carries matches.
///
/// Fail-closed everywhere: labeling errors degrade to empty text and the
/// worker's per-file capture records the file, never aborting the pass.
/// First use may download the ML Kit models via Play Services (a few MB,
/// then fully offline).
class MlKitPhotoExtractor implements FeatureExtractor {
  /// Labels below this confidence are dropped (ML Kit default).
  static const confidenceFloor = 0.5;

  /// Cap stored labels per photo (FTS weight + index size).
  static const maxLabels = 12;

  final LabelBackend backend;
  final OcrBackend ocr;

  MlKitPhotoExtractor({LabelBackend? backend, OcrBackend? ocr})
      : backend = backend ?? const MlKitLabelBackend(),
        ocr = ocr ?? const MlKitOcrBackend();

  @override
  String get modelVersion => 'mlkit-labels-v4';

  @override
  Future<IndexFeatures> extract(MediaEntry entry) async {
    var text = '';
    final id = photoAssetIdFromUri(entry.uri);
    if (id != null) {
      try {
        final asset = await AssetEntity.fromId(id);
        if (entry.isVideo) {
          text = await _describeVideoThumbnail(asset);
        } else {
          final file = await asset?.file;
          if (file != null) {
            text = await _describeFile(file.path);
          }
        }
      } catch (_) {
        text = '';
      }
    }
    // Stub-geometry vector (see class docs); real content signal is `text`.
    final vec = Uint8List.fromList(stubEmbedText(entry.uri, 32));
    return IndexFeatures(vector: vec, ocrText: text);
  }

  /// Labels + OCR words for a file path, deduped with labels first.
  Future<String> _describeFile(String path) async {
    final labels = await backend.labelFile(path);
    final words = await MlKitOcr(backend: ocr).readWords(path);
    return _merge(labels, words);
  }

  /// Videos: same treatment on the OS-cached thumbnail bytes (labels +
  /// OCR through one shared temp file).
  Future<String> _describeVideoThumbnail(AssetEntity? asset) async {
    final bytes = await videoThumbnailBytes(asset);
    if (bytes == null) return '';
    return describeJpegBytes(bytes, backend, ocr);
  }

  /// Labels + OCR for JPEG bytes via a single temp file (ML Kit needs a
  /// path, not bytes). Temp file is deleted before return. Shared with
  /// the CLIP-era extractor.
  static Future<String> describeJpegBytes(
    Uint8List bytes,
    LabelBackend labels,
    OcrBackend ocr,
  ) async {
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      tmp = File(
        '${dir.path}/qp_vthumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tmp.writeAsBytes(bytes, flush: true);
      final a = await labels.labelFile(tmp.path);
      final b = await MlKitOcr(backend: ocr).readWords(tmp.path);
      return _merge(a, b);
    } catch (_) {
      return '';
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {}
    }
  }

  /// Merge "labels first, then OCR words", deduped. Labels describe the
  /// scene; OCR carries literal text — both searchable through one column.
  static String _merge(String labels, String words) {
    final out = <String>[];
    for (final w in '${labels.trim()} ${words.trim()}'.split(
      RegExp(r'\s+'),
    )) {
      if (w.isNotEmpty && !out.contains(w)) out.add(w);
    }
    return out.join(' ');
  }

  /// OS-cached video thumbnail bytes (300px), null when unavailable.
  /// Shared with the CLIP-era extractor (same bytes feed the image tower).
  static Future<Uint8List?> videoThumbnailBytes(AssetEntity? asset) async {
    if (asset == null) return null;
    try {
      final thumb = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(300),
      );
      if (thumb == null || thumb.isEmpty) return null;
      return thumb;
    } catch (_) {
      return null;
    }
  }

  /// Label JPEG bytes through [backend] via a temp file (ML Kit needs a
  /// path, not bytes). Temp file is deleted before return.
  static Future<String> labelJpegBytes(
    Uint8List bytes,
    LabelBackend backend,
  ) async {
    File? tmp;
    try {
      final dir = await getTemporaryDirectory();
      tmp = File(
        '${dir.path}/qp_vthumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tmp.writeAsBytes(bytes, flush: true);
      return await backend.labelFile(tmp.path);
    } catch (_) {
      return '';
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {}
    }
  }
}

/// Label backend behind an interface: real ML Kit on device, fakes in tests.
abstract class LabelBackend {
  /// Space-separated label words for the file, confidence-filtered.
  Future<String> labelFile(String path);
}

/// Production backend: ML Kit on-device labeler (app-lifetime instance).
class MlKitLabelBackend implements LabelBackend {
  const MlKitLabelBackend();

  static ImageLabeler? _labeler;

  @override
  Future<String> labelFile(String path) async {
    _labeler ??= ImageLabeler(
      options: ImageLabelerOptions(
        confidenceThreshold: MlKitPhotoExtractor.confidenceFloor,
      ),
    );
    final found = await _labeler!.processImage(
      InputImage.fromFilePath(path),
    );
    final words = <String>[];
    for (final label in found.take(MlKitPhotoExtractor.maxLabels)) {
      for (final w in label.label.toLowerCase().split(RegExp(r'\s+'))) {
        if (w.isNotEmpty && !words.contains(w)) words.add(w);
      }
      if (words.length >= MlKitPhotoExtractor.maxLabels) break;
    }
    return words.join(' ');
  }
}

/// Deterministic test backend: canned labels per path substring.
class FakeLabelBackend implements LabelBackend {
  final Map<String, String> canned;
  const FakeLabelBackend(this.canned);

  @override
  Future<String> labelFile(String path) async {
    for (final e in canned.entries) {
      if (path.contains(e.key)) return e.value;
    }
    return '';
  }
}
