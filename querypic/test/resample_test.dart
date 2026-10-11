import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/resample.dart';

/// Pure-logic tests for PCM decode + bandlimited resampling
/// (host-runnable). The previous linear resampler lived in untestable
/// Kotlin and aliased badly; everything here runs on-device code paths.

/// Normalized Goertzel magnitude at [targetHz] for [sr] audio.
double goertzel(List<double> x, double targetHz, int sr) {
  final w = 2 * math.pi * targetHz / sr;
  final cw = math.cos(w);
  var s0 = 0.0;
  var s1 = 0.0;
  var s2 = 0.0;
  for (final v in x) {
    s0 = v + 2 * cw * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  final p = s1 * s1 + s2 * s2 - 2 * cw * s1 * s2;
  return math.sqrt(math.max(p, 0)) / x.length;
}

void main() {
  group('Pcm.decodeMono', () {
    test('decodes int16 LE mono', () {
      final bytes = Uint8List.fromList([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]);
      final out = Pcm.decodeMono(bytes, channels: 1, encoding: 2);
      expect(out.encodingUsed, 's16');
      expect(out.mono.length, 3);
      expect(out.mono[0], closeTo(0.0, 1e-9));
      expect(out.mono[1], closeTo(32767 / 32768.0, 1e-9));
      expect(out.mono[2], closeTo(-1.0, 1e-9));
    });

    test('decodes float32 LE mono', () {
      final bd = ByteData(8);
      bd.setFloat32(0, 0.5, Endian.little);
      bd.setFloat32(4, -0.25, Endian.little);
      final out = Pcm.decodeMono(
        bd.buffer.asUint8List(),
        channels: 1,
        encoding: 4,
      );
      expect(out.encodingUsed, 'f32');
      expect(out.mono[0], closeTo(0.5, 1e-6));
      expect(out.mono[1], closeTo(-0.25, 1e-6));
    });

    test('downmixes stereo by mean', () {
      final bd = ByteData(4);
      bd.setInt16(0, 16384, Endian.little);
      bd.setInt16(2, -16384, Endian.little);
      final out = Pcm.decodeMono(
        bd.buffer.asUint8List(),
        channels: 2,
        encoding: 2,
      );
      expect(out.mono.length, 1);
      expect(out.mono[0], closeTo(0.0, 1e-9));
    });

    test('falls back across a lying flag', () {
      // Loud int16 speech-like bytes flagged as float32: the float
      // misread explodes, so the int16 fallback must win.
      final rnd = math.Random(7);
      final bd = ByteData(4000);
      for (var i = 0; i < 2000; i++) {
        bd.setInt16(i * 2, (rnd.nextDouble() * 20000 - 10000).toInt(),
            Endian.little,);
      }
      final out = Pcm.decodeMono(
        bd.buffer.asUint8List(),
        channels: 1,
        encoding: 4,
      );
      expect(out.encodingUsed, 's16*');
    });
  });

  group('Resampler.resample16k', () {
    test('preserves a 1 kHz tone through 44100 -> 16000', () {
      final src = List<double>.generate(
        44100,
        (i) => 0.5 * math.sin(2 * math.pi * 1000 * i / 44100),
      );
      final out = Resampler.resample16k(src, 44100);
      expect(out.length, 16000);
      expect(goertzel(out, 1000, 16000), greaterThan(0.15));
    });

    test('rejects aliases: 12 kHz in, no 4 kHz out', () {
      final src = List<double>.generate(
        44100,
        (i) => 0.5 * math.sin(2 * math.pi * 12000 * i / 44100),
      );
      final out = Resampler.resample16k(src, 44100);
      // Steady-state rejection is essentially perfect; measure the
      // interior so edge transients (renormalization overshoot on the
      // first/last ~1000 samples) don't pollute the assertion.
      final body = out.sublist(1000, out.length - 1000);
      var peak = 0.0;
      for (final v in body) {
        final a = v.abs();
        if (a > peak) peak = a;
      }
      expect(peak, lessThan(0.02));
      expect(goertzel(out, 4000, 16000), lessThan(0.01));
    });

    test('unity DC gain', () {
      final out = Resampler.resample16k(
        List<double>.filled(44100, 0.5),
        44100,
      );
      var mean = 0.0;
      for (final v in out.skip(1000).take(14000)) {
        mean += v / 14000;
      }
      expect(mean, closeTo(0.5, 0.01));
    });

    test('exact-ratio 48000 -> 16000 keeps tone', () {
      final src = List<double>.generate(
        48000,
        (i) => 0.5 * math.sin(2 * math.pi * 1000 * i / 48000),
      );
      final out = Resampler.resample16k(src, 48000);
      expect(out.length, 16000);
      expect(goertzel(out, 1000, 16000), greaterThan(0.15));
    });

    test('empty and passthrough inputs', () {
      expect(Resampler.resample16k(const [], 44100), isEmpty);
      final same = Resampler.resample16k([0.1, 0.2], 16000);
      expect(same, [0.1, 0.2]);
    });
  });

  group('Pcm.readWavFile', () {
    // Builds a minimal 16-bit mono WAV in memory: 44-byte header + samples.
    Uint8List wavBytes(List<int> samples16) {
      final dataLen = samples16.length * 2;
      final buf = ByteData(44 + dataLen);
      void ascii(int at, String s) {
        for (var i = 0; i < s.length; i++) {
          buf.setUint8(at + i, s.codeUnitAt(i));
        }
      }

      void u32(int at, int v) => buf.setUint32(at, v, Endian.little);
      void u16(int at, int v) => buf.setUint16(at, v, Endian.little);
      ascii(0, 'RIFF');
      u32(4, 36 + dataLen);
      ascii(8, 'WAVE');
      ascii(12, 'fmt ');
      u32(16, 16);
      u16(20, 1);
      u16(22, 1);
      u32(24, 16000);
      u32(28, 32000);
      u16(32, 2);
      u16(34, 16);
      ascii(36, 'data');
      u32(40, dataLen);
      for (var i = 0; i < samples16.length; i++) {
        buf.setInt16(44 + i * 2, samples16[i], Endian.little);
      }
      return buf.buffer.asUint8List();
    }

    test('parses PCM16 mono wav', () async {
      final dir = await Directory.systemTemp.createTemp('qp_wav');
      try {
        final file = File('${dir.path}/t.wav');
        await file.writeAsBytes(wavBytes([0, 32767, -32768]));
        final w = await Pcm.readWavFile(file.path);
        expect(w.sampleRate, 16000);
        expect(w.channels, 1);
        expect(w.encoding, 2);
        final decoded = Pcm.decodeMono(
          w.pcm,
          channels: w.channels,
          encoding: w.encoding,
        );
        expect(decoded.encodingUsed, 's16');
        expect(decoded.mono[0], closeTo(0.0, 1e-9));
        expect(decoded.mono[1], closeTo(32767 / 32768.0, 1e-9));
        expect(decoded.mono[2], closeTo(-1.0, 1e-9));
      } finally {
        // Best-effort: Windows often holds temp files briefly.
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('rejects non-WAV bytes with a clear error', () async {
      final dir = await Directory.systemTemp.createTemp('qp_wav');
      try {
        final file = File('${dir.path}/t.wav');
        await file.writeAsBytes([1, 2, 3, 4]);
        expect(
          () => Pcm.readWavFile(file.path),
          throwsA(isA<StateError>()),
        );
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
