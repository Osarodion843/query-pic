import 'search_service.dart';

/// Production CLIP text tower (Phase 6, task 2; PRD §3).
/// Loads `clip_text_s2.tflite` (32MB) on device.
class TfliteTextEmbedder implements TextEmbedder {
  @override
  int get dimension => 512; // Standard CLIP-ViT-B/32 or similar.

  @override
  Future<List<int>> embed(String query) async {
    // TODO: Wire tflite_flutter Interpreter here.
    // 1. Tokenize query (BPE).
    // 2. run() inference.
    // 3. Quantize float32 -> INT8.
    throw UnimplementedError('Binary .tflite models required for device build.');
  }
}

/// Vector search optimization for 100k+ rows (Phase 6, task 4).
/// Brute-force cosine scan is O(N); HNSW/IVF provides O(log N).
class VectorIndex {
  // Logic for HNSW (Hierarchical Navigable Small World) lands here
  // when brute-force scan exceeds 100ms budget.
}
