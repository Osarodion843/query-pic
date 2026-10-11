/// Deterministic text -> 0-255 vector: the stand-in for the CLIP text tower
/// until clip_text_s2.tflite lands on device.
///
/// Shared by StubTextEmbedder (queries + seeded rows), SyntheticFrameExtractor
/// (debug frame vectors) and StubFeatureExtractor (photo placeholder vectors)
/// so the same string always embeds to the same bytes on every path.
///
/// Contract (mirrored byte-for-byte by tools/diag_phase4.py stub_embed):
/// FNV-1a (32-bit) over UTF-16 code units, then xorshift32 expanding one
/// byte per dimension. State stays full-width throughout — an earlier
/// per-dimension `& 0xFF` masked the chain down to 8 bits, collapsing ~20k
/// texts into <=256 distinct vectors (~78 rows then matched every query at
/// cos=1.0 and flooded the top-K scans with random results).
List<int> stubEmbedText(String text, int dimension) {
  var h = 0x811C9DC5;
  for (final cu in text.codeUnits) {
    h = (h ^ cu) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  if (h == 0) h = 0x9E3779B9;
  return List<int>.generate(dimension, (_) {
    h ^= (h << 13) & 0xFFFFFFFF;
    h ^= h >> 17;
    h ^= (h << 5) & 0xFFFFFFFF;
    h &= 0xFFFFFFFF;
    return h & 0xFF;
  });
}
