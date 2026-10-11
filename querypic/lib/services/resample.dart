import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// PCM decode + bandlimited resampling (Step 5 STT wiring).
///
/// The native extractor returns RAW decoder bytes with format metadata;
/// everything below is pure, unit-tested Dart. (An earlier linear
/// resampler lived in untestable Kotlin and aliased badly: content above
/// the 8 kHz output Nyquist folded straight into speech bands.)
class Pcm {
  /// Read a WAV file straight to raw PCM bytes (Step 5 debug path).
  /// No MediaCodec involved (none exists for audio/raw). Supports PCM
  /// 16-bit and float32; anything else throws a clear StateError.
  static Future<
      ({
        int sampleRate,
        int channels,
        int encoding,
        Uint8List pcm,
      })> readWavFile(String path) async {
    final bytes = await File(path).readAsBytes();
    String tag(int at) =>
        String.fromCharCodes(bytes.sublist(at, at + 4));
    int u32(int at) =>
        bytes[at] |
        (bytes[at + 1] << 8) |
        (bytes[at + 2] << 16) |
        (bytes[at + 3] << 24);
    int u16(int at) => bytes[at] | (bytes[at + 1] << 8);
    if (bytes.lengthInBytes < 44 ||
        tag(0) != 'RIFF' ||
        tag(8) != 'WAVE') {
      throw StateError('not a RIFF/WAVE file: $path');
    }
    var fmtCode = 0;
    var channels = 0;
    var rate = 0;
    var bits = 0;
    var dataOff = -1;
    var dataLen = 0;
    var at = 12;
    while (at + 8 <= bytes.lengthInBytes) {
      final id = tag(at);
      final size = u32(at + 4);
      if (id == 'fmt ' && size >= 16) {
        fmtCode = u16(at + 8);
        channels = u16(at + 10);
        rate = u32(at + 12);
        bits = u16(at + 22);
      } else if (id == 'data') {
        dataOff = at + 8;
        dataLen = size;
      }
      at += 8 + size + (size % 2);
    }
    if (fmtCode != 1) {
      throw StateError(
        'WAV is not PCM (format $fmtCode): $path',
      );
    }
    if (dataOff < 0) throw StateError('WAV has no data chunk: $path');
    final encoding = bits == 32 ? 4 : 2;
    if (bits != 16 && bits != 32) {
      throw StateError('WAV bit depth $bits not supported: $path');
    }
    final end = (dataOff + dataLen).clamp(0, bytes.lengthInBytes);
    return (
      sampleRate: rate == 0 ? 16000 : rate,
      channels: channels == 0 ? 1 : channels,
      encoding: encoding,
      pcm: Uint8List.sublistView(bytes, dataOff, end),
    );
  }

  /// Decode interleaved LE bytes to mono doubles.
  /// [encoding]: 2 = int16 (Android ENCODING_PCM_16BIT), 4 = float32.
  /// Never trusts the flag blindly: tries the flagged encoding, falls
  /// back to the other when values are insane (non-finite or peak above
  /// 32 — real PCM never gets there), zeros when both fail. Returns the
  /// encoding actually used ('*' marks fallback).
  static ({List<double> mono, String encodingUsed}) decodeMono(
    Uint8List bytes, {
    required int channels,
    required int encoding,
  }) {
    final ch = channels <= 0 ? 1 : channels;

    List<double> asInt16() {
      final bd = ByteData.sublistView(bytes);
      final n = bytes.lengthInBytes ~/ 2;
      final frames = n ~/ ch;
      return List<double>.generate(frames, (f) {
        var acc = 0.0;
        for (var c = 0; c < ch; c++) {
          final i = f * ch + c;
          acc += (i * 2 + 1 < bytes.lengthInBytes)
              ? bd.getInt16(i * 2, Endian.little) / 32768.0
              : 0.0;
        }
        return acc / ch;
      });
    }

    List<double> asFloat32() {
      final bd = ByteData.sublistView(bytes);
      final n = bytes.lengthInBytes ~/ 4;
      final frames = n ~/ ch;
      return List<double>.generate(frames, (f) {
        var acc = 0.0;
        for (var c = 0; c < ch; c++) {
          final i = f * ch + c;
          acc += (i * 4 + 3 < bytes.lengthInBytes)
              ? bd.getFloat32(i * 4, Endian.little)
              : 0.0;
        }
        return acc / ch;
      });
    }

    // Real PCM is finite and small; int16 bytes misread as float
    // explode (NaN/huge). A reverse lie (float bytes read as int16)
    // stays bounded and therefore always passes this gate — accepted
    // residual risk (never observed); a whiteness gate was tried and
    // dropped for false-rejecting white-ish genuine input.
    bool sane(List<double> v) {
      for (final s in v) {
        if (!s.isFinite || s.abs() > 32.0) return false;
      }
      return true;
    }

    if (encoding == 4) {
      final f = asFloat32();
      if (sane(f)) return (mono: f, encodingUsed: 'f32');
      final i = asInt16();
      if (sane(i)) return (mono: i, encodingUsed: 's16*');
    } else {
      final i = asInt16();
      if (sane(i)) return (mono: i, encodingUsed: 's16');
      final f = asFloat32();
      if (sane(f)) return (mono: f, encodingUsed: 'f32*');
    }
    return (
      mono: List<double>.filled(bytes.lengthInBytes ~/ 2, 0.0),
      encodingUsed: 'none',
    );
  }
}

/// Bandlimited resampler to 16 kHz mono (Step 5 STT wiring).
/// Windowed-sinc kernel (Hann, half-width 32 input samples, cutoff at
/// the 8 kHz output Nyquist), weights renormalized per position so edges
/// and short inputs stay unity-gain. Pure — unit-tested (sine fidelity,
/// alias rejection, DC gain).
class Resampler {
  static const outRate = 16000;
  static const _half = 32;

  static List<double> resample16k(List<double> src, int srcRate) {
    if (src.isEmpty || srcRate <= 0) return const [];
    if (srcRate == outRate) return List<double>.from(src);
    final ratio = srcRate / outRate;
    final fc = 8000.0 / srcRate;
    final outLen = (src.length / ratio).floor();
    final out = List<double>.filled(outLen, 0.0);
    for (var m = 0; m < outLen; m++) {
      final pos = m * ratio;
      final i0 = pos.floor();
      var acc = 0.0;
      var wsum = 0.0;
      for (var k = -_half; k <= _half; k++) {
        final n = i0 + k;
        if (n < 0 || n >= src.length) continue;
        final t = pos - n;
        final x = 2 * math.pi * fc * t;
        final sinc = t == 0 ? 1.0 : math.sin(x) / x;
        final w = sinc * (0.5 * (1 + math.cos(math.pi * t / _half)));
        acc += src[n] * w;
        wsum += w;
      }
      out[m] = wsum == 0 ? 0.0 : acc / wsum;
    }
    return out;
  }
}

