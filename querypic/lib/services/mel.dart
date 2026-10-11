import 'dart:math' as math;
import 'dart:typed_data';

/// Log-mel frontend matching openai/whisper audio.py EXACTLY (Phase 5 STT).
/// 16 kHz, n_fft 400, 25 ms periodic-Hann window, 10 ms hop, 80 Slaney
/// mel bins, center reflect-padding, last frame dropped, log10 +
/// max-8 clamp + (x+4)/4 normalization, 3000 frames / 30 s.
///
/// An earlier revision used a 512-point FFT for speed; a host reference
/// check measured 51% relative divergence on tonal content and 81% on
/// low-frequency content, which produced word salad on device. The exact
/// 400-point DFT below uses precomputed twiddle tables (one-time ~1.3 MB)
/// and stays within the realtime budget. Pure — unit-tested, including a
/// Python reference cross-check (tools/_melref_tmp.py).
class WhisperMel {
  static const sampleRate = 16000;
  static const nFft = 400;
  static const hopLength = 160;
  static const winLength = 400;
  static const nMels = 80;
  static const chunkFrames = 3000; // 30 s at 10 ms hop

  /// Forward-DFT twiddle tables: [201][400]. Static finals initialize
  /// lazily on first use.
  static final List<Float64List> _cosT = List<Float64List>.generate(
    nFft ~/ 2 + 1,
    (k) => Float64List.fromList(
      List<double>.generate(
        nFft,
        (n) => math.cos(2 * math.pi * k * n / nFft),
      ),
    ),
  );
  static final List<Float64List> _sinT = List<Float64List>.generate(
    nFft ~/ 2 + 1,
    (k) => Float64List.fromList(
      List<double>.generate(
        nFft,
        (n) => math.sin(2 * math.pi * k * n / nFft),
      ),
    ),
  );

  static List<double> _hannPeriodic() => List<double>.generate(
        winLength,
        (i) => 0.5 * (1 - math.cos(2 * math.pi * i / winLength)),
      );

  /// Mirror index for reflect padding (torch.nn.functional.pad mode
  /// 'reflect'), valid for any non-empty input.
  static int _reflectIndex(int i, int n) {
    if (n < 2) return 0;
    while (i < 0 || i >= n) {
      if (i < 0) i = -i;
      if (i >= n) i = 2 * (n - 1) - i;
    }
    return i;
  }

  /// [frames] x [nMels] log-mel rows for mono 16 kHz [pcm].
  /// Frame count is 1 + N/160 with the last frame dropped (torch
  /// [..., :-1] semantics): exactly 3000 rows for 480000 samples.
  static List<List<double>> compute(List<double> pcm) {
    final n = pcm.length;
    final window = _hannPeriodic();
    final filters = _melFilters();
    // Center reflect-padded signal.
    final padded = List<double>.generate(
      n + 2 * (nFft ~/ 2),
      (j) => n == 0 ? 0.0 : pcm[_reflectIndex(j - nFft ~/ 2, n)],
    );
    final nFrames = 1 + n ~/ hopLength;
    final rows = <List<double>>[];
    for (var f = 0; f < nFrames - 1; f++) {
      final base = f * hopLength;
      // Exact 400-point power spectrum (first 201 bins).
      var pIdx = 0;
      final power = List<double>.filled(nFft ~/ 2 + 1, 0);
      for (var k = 0; k <= nFft ~/ 2; k++) {
        var re = 0.0;
        var im = 0.0;
        final cosRow = _cosT[k];
        final sinRow = _sinT[k];
        for (var m = 0; m < nFft; m++) {
          final x = padded[base + m] * window[m];
          re += x * cosRow[m];
          im -= x * sinRow[m];
        }
        power[pIdx++] = re * re + im * im;
      }
      final row = List<double>.filled(nMels, 0);
      for (var m = 0; m < nMels; m++) {
        var e = 0.0;
        final filt = filters[m];
        for (var k = 0; k < filt.length; k++) {
          e += filt[k] * power[k];
        }
        row[m] = e;
      }
      rows.add(row);
    }
    // log10 floor, peak-relative clamp, normalize (whisper audio.py).
    var peak = -1e30;
    for (final row in rows) {
      for (var m = 0; m < nMels; m++) {
        row[m] = math.log(math.max(row[m], 1e-10)) / math.ln10;
        if (row[m] > peak) peak = row[m];
      }
    }
    for (final row in rows) {
      for (var m = 0; m < nMels; m++) {
        row[m] = (math.max(row[m], peak - 8.0) + 4.0) / 4.0;
      }
    }
    return rows;
  }

  /// Pad or trim frame rows to exactly [chunkFrames] x [nMels].
  /// Padding uses the silence floor (callers normally pad the PCM first,
  /// which is the exact whisper behavior; this is a safety net).
  static List<List<double>> chunkWindow(List<List<double>> frames) {
    if (frames.length >= chunkFrames) {
      return frames.sublist(0, chunkFrames);
    }
    final pad = List<List<double>>.generate(
      chunkFrames - frames.length,
      (_) => List<double>.filled(nMels, -1.5),
    );
    return [...frames, ...pad];
  }

  /// Slaney 80-band triangular filterbank over nFft/2+1 bins at 16 kHz,
  /// area-normalized (librosa-compatible).
  static List<List<double>> _melFilters() {
    const fMin = 0.0;
    const fMax = 8000.0;
    double hzToMel(double hz) =>
        hz >= 1000 ? 15.0 + math.log(hz / 1000.0) / 0.0687516818808784 : hz * 3.0 / 200.0;
    double melToHz(double mel) =>
        mel >= 15.0 ? 1000.0 * math.exp(0.0687516818808784 * (mel - 15.0)) : mel * 200.0 / 3.0;
    final melMin = hzToMel(fMin);
    final melMax = hzToMel(fMax);
    final points = List<double>.generate(
      nMels + 2,
      (i) => melToHz(melMin + i * (melMax - melMin) / (nMels + 1)),
    );
    const bins = nFft ~/ 2 + 1;
    final filters = <List<double>>[];
    for (var m = 1; m <= nMels; m++) {
      final row = List<double>.filled(bins, 0);
      final f0 = points[m - 1];
      final f1 = points[m];
      final f2 = points[m + 1];
      for (var k = 0; k < bins; k++) {
        final freq = k * sampleRate / nFft;
        double w = 0;
        if (freq >= f0 && freq <= f1 && f1 > f0) {
          w = (freq - f0) / (f1 - f0);
        } else if (freq > f1 && freq <= f2 && f2 > f1) {
          w = (f2 - freq) / (f2 - f1);
        }
        row[k] = w;
      }
      // Slaney area normalization.
      final enorm = 2.0 / (f2 - f0);
      for (var k = 0; k < bins; k++) {
        row[k] *= enorm;
      }
      filters.add(row);
    }
    return filters;
  }
}
