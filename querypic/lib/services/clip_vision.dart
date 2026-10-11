import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// CLIP image tower frontend (Step 5).
///
/// Decodes any image bytes, center-crops to square, resizes to 224×224 and
/// emits NCHW float32 normalized with the CLIP channel mean/std. Pure Dart
/// (package:image) — host-testable bit-for-bit; the device runs this exact
/// code before the TFLite joint model. 224 = ViT-B/32 native resolution.
/// Mean/std are the shared OpenAI CLIP constants (identical for the LAION
/// MIT checkpoint — same BPE family, same preprocessing).
class ClipVision {
  static const size = 224;

  /// OpenAI CLIP normalization (RGB order).
  static const mean = [0.48145466, 0.4578275, 0.40821073];
  static const std = [0.26862954, 0.26130258, 0.27577711];

  /// Returns [3][224][224] row-major floats (channel-first), or null when
  /// the bytes are not a decodable image.
  static Float32List? preprocess(Uint8List bytes) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      return null; // corrupt/truncated files fail here, never upstream.
    }
    if (decoded == null) return null;
    final square = _centerCropSquare(decoded);
    final resized =
        img.copyResize(square, width: size, height: size);
    final out = Float32List(3 * size * size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final p = resized.getPixel(x, y);
        // package:image channels are 0..255 (r/g/b getters normalized).
        final r = p.r / 255.0;
        final g = p.g / 255.0;
        final b = p.b / 255.0;
        out[y * size + x] = (r - mean[0]) / std[0];
        out[size * size + y * size + x] = (g - mean[1]) / std[1];
        out[2 * size * size + y * size + x] = (b - mean[2]) / std[2];
      }
    }
    return out;
  }

  static img.Image _centerCropSquare(img.Image src) {
    final side = src.width < src.height ? src.width : src.height;
    final ox = (src.width - side) ~/ 2;
    final oy = (src.height - side) ~/ 2;
    return img.copyCrop(src, x: ox, y: oy, width: side, height: side);
  }
}
