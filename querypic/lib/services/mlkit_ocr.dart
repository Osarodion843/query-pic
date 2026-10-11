import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// On-device OCR text-in-image search (PRD §3).
///
/// ML Kit's Latin text recognizer reads words printed inside photos,
/// screenshots, posters and memes; those words land in the FTS-indexed OCR
/// text column, so a query like "following" matches images CONTAINING that
/// text — never filenames. Same distribution story as image labeling:
/// first use may fetch the recognition model via Play Services (a few MB),
/// then fully offline. Fail-closed: errors degrade to empty text.
///
/// Words are lowercased, deduplicated, length>=3 (matches the index
/// tokenizer, which drops shorts) and capped — receipts and posters are
/// wordy, and the FTS column shouldn't balloon per photo.
class MlKitOcr {
  /// Cap stored OCR words per image (FTS weight + index size).
  static const maxWords = 60;

  final OcrBackend backend;

  MlKitOcr({OcrBackend? backend})
      : backend = backend ?? const MlKitOcrBackend();

  Future<String> readWords(String path) async {
    try {
      return await backend.readText(path);
    } catch (_) {
      return '';
    }
  }

  /// Raw recognizer text -> capped, deduped index words. Pure.
  static String toIndexWords(String raw) {
    final words = <String>[];
    for (final w in raw.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (w.length >= 3 && !words.contains(w)) words.add(w);
      if (words.length >= maxWords) break;
    }
    return words.join(' ');
  }
}

/// Text backend behind an interface: real ML Kit on device, fakes in tests.
abstract class OcrBackend {
  /// Space-separated index words read from the image at [path].
  Future<String> readText(String path);
}

/// Production backend: ML Kit on-device recognizer (app-lifetime instance).
class MlKitOcrBackend implements OcrBackend {
  const MlKitOcrBackend();

  static TextRecognizer? _recognizer;

  @override
  Future<String> readText(String path) async {
    _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
    final result = await _recognizer!.processImage(
      InputImage.fromFilePath(path),
    );
    return MlKitOcr.toIndexWords(result.text);
  }
}

/// Deterministic test backend: canned words per path substring.
class FakeOcrBackend implements OcrBackend {
  final Map<String, String> canned;
  const FakeOcrBackend(this.canned);

  @override
  Future<String> readText(String path) async {
    for (final e in canned.entries) {
      if (path.contains(e.key)) return MlKitOcr.toIndexWords(e.value);
    }
    return '';
  }
}
