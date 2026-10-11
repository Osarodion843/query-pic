import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'audio_extractor.dart';
import 'guardrails.dart';
import 'media_source.dart';
import 'mel.dart';
import 'resample.dart';
import 'stt_indexer.dart';
import 'stt_worker.dart';
import 'whisper_decoder.dart';
import 'whisper_vocab.dart';

/// Real on-device STT (Phase 5, task 2; Step 5 wiring).
/// Loads whisper-with-timestamp-tiny-en.tflite from app assets with the
/// whisper vocab; falls back (load() == false) to [StubSttEngine] behavior
/// (empty segments) whenever assets,NNAPI/CPU delegates, or audio are
/// unavailable. Audio comes from local file paths via the querypic/audio
/// channel (MediaCodec on Android); demo://, content:// and remote URIs
/// are out of scope for the debug path and yield no segments.
///
/// Model stays registered in [ModelCache] so RAM pressure can unload it.
class TfliteSttEngine implements SttEngine {
  final String modelAsset;
  final String vocabAsset;

  /// Inference threads. Single-thread was tried during diagnosis
  /// (identical output class — threading exonerated); 4 threads buys
  /// realtime margin on octa-core devices.
  final int numThreads;
  Interpreter? _interp;
  WhisperVocab? _vocab;
  List<int> _outShape = const [1, 448];

  /// Seconds of audio per second of wall time for the last transcribe()
  /// (extraction + mel + inference). -1 when nothing ran.
  double lastRealtimeFactor = -1;

  /// Last load/transcribe error, surfaced by the Model status row.
  String? lastError;

  /// Stack of the last invoke failure (truncated in the UI dialog).
  String? lastStack;

  /// Input/output tensor signatures read at load (diagnostics).
  String tensorInfo = 'unknown';

  TfliteSttEngine({
    this.modelAsset = 'sandbox/models/whisper-tiny-transcribe-translate.tflite',
    this.vocabAsset = 'sandbox/models/whisper_vocab.json',
    this.numThreads = 4,
  });

  @override
  String get modelVersion => 'whisper-tiny-transcribe-translate-tflite';

  bool get isLoaded => _interp != null && _vocab != null;
  List<int> get outputShape => _outShape;
  int get vocabSize => _vocab?.idToToken.length ?? 0;

  Future<bool> load() async {
    if (isLoaded) return true;
    try {
      final options = InterpreterOptions()..threads = numThreads;
      _interp = await Interpreter.fromAsset(modelAsset, options: options);
      final inT = _interp!.getInputTensor(0);
      final outT = _interp!.getOutputTensor(0);
      tensorInfo = 'in ${inT.shape} ${inT.type} / '
          'out ${outT.shape} ${outT.type}';
      final shape = outT.shape;
      if (shape.length == 2) _outShape = shape;
      _vocab = WhisperVocab.parse(await rootBundle.loadString(vocabAsset));
      ModelCache.markLoaded('whisper-tiny');
      lastError = null;
      return true;
    } catch (e) {
      lastError = '$e';
      _interp = null;
      return false;
    }
  }

  /// Replace non-finite samples with silence. Returns cleaned samples
  /// plus the sanitized count (diagnostic: nonzero means the extractor
  /// handed us NaN/Inf, e.g. stale buffer positions on some OEMs).
  /// Never mutates the input (channel-provided views are unmodifiable);
  /// copies only when something actually needs cleaning. Pure.
  static (List<double> samples, int sanitized) sanitizePcm(
    List<double> pcm,
  ) {
    var n = 0;
    for (final s in pcm) {
      if (!s.isFinite) n++;
    }
    if (n == 0) return (pcm, 0);
    var i = 0;
    final out = List<double>.filled(pcm.length, 0.0);
    for (final s in pcm) {
      out[i++] = s.isFinite ? s : 0.0;
    }
    return (out, n);
  }
  /// and absolute paths (adb-pushed test video) are supported.
  /// Parsed manually (not Uri.toFilePath, which is platform-dependent
  /// and returns backslashes on Windows hosts).
  static String? localPathFor(String uri) {
    const prefix = 'file://';
    if (uri.startsWith(prefix)) {
      var rest = uri.substring(prefix.length);
      if (rest.startsWith('localhost/')) {
        rest = rest.substring('localhost'.length);
      }
      return rest.isNotEmpty ? rest : null;
    }
    if (uri.startsWith('/')) return uri;
    return null;
  }

  @override
  Future<List<SpeechSegment>> transcribe(MediaEntry entry) async {
    if (!await load()) return const [];
    final path = localPathFor(entry.uri);
    if (path == null) return const [];
    final vocab = _vocab!;
    final sw = Stopwatch()..start();
    final out = <SpeechSegment>[];
    lastChunkInfo.clear();
    var audioSecs = 0.0;
    for (var chunk = 0; chunk < 20; chunk++) {
      final start = chunk * 30.0;
      // All formats (MP4 via decoder, WAV natively) arrive as raw
      // bytes + metadata through the one channel; decode, downmix
      // and resample in tested Dart code.
      final raw = await AudioExtractor.extractPcm(
        path,
        startSec: start,
        durSec: 30.0,
      );
      if (raw == null || raw.pcm.isEmpty) break;
      lastExtVersion = raw.ext;
      final byteLen = raw.pcm.lengthInBytes;
      final decoded = Pcm.decodeMono(
        raw.pcm,
        channels: raw.channels,
        encoding: raw.encoding,
      );
      var mono = Resampler.resample16k(decoded.mono, raw.sampleRate);
      audioSecs += mono.length / 16000.0;
      final cleaned = sanitizePcm(mono);
      var samples = cleaned.$1;
      // Whisper pads audio (not features) to 30 s; mel-level zero
      // padding would write the wrong floor values.
      const need = 30 * 16000;
      if (samples.length < need) {
        samples = [
          ...samples,
          ...List<double>.filled(need - samples.length, 0.0),
        ];
      }
      final nanCount = cleaned.$2;
      var peak = 0.0;
      var sumSq = 0.0;
      for (final s in samples) {
        final a = s.abs();
        if (a > peak) peak = a;
        sumSq += s * s;
      }
      final rms =
          samples.isEmpty ? 0.0 : math.sqrt(sumSq / samples.length);
      final mel = WhisperMel.compute(samples);
      var melMean = 0.0;
      var melVar = 0.0;
      var melN = 0;
      for (final row in mel) {
        for (final v in row) {
          melMean += v;
          melN++;
        }
      }
      melMean = melN == 0 ? 0.0 : melMean / melN;
      for (final row in mel) {
        for (final v in row) {
          final d = v - melMean;
          melVar += d * d;
        }
      }
      final melStd = melN == 0 ? 0.0 : math.sqrt(melVar / melN);
      final seqs = _run(WhisperMel.chunkWindow(mel));
      final segs = decodeWhisperSegments(
        seqs,
        vocab,
        chunkOffsetSecs: start,
      );
      if (lastChunkInfo.length < 6) {
        lastChunkInfo.add(
          'c$chunk bytes=$byteLen enc=${decoded.encodingUsed} '
          'rms=${rms.toStringAsFixed(4)} peak=${peak.toStringAsFixed(3)} '
          'nan=$nanCount mel=${melMean.toStringAsFixed(3)}/'
          '${melStd.toStringAsFixed(3)} '
          'ids=[${seqs.take(10).join(',')}] segs=${segs.length}',
        );
      }
      for (final s in segs) {
        out.add(
          SpeechSegment(tStart: s.start, tEnd: s.end, text: s.text),
        );
      }
      // End the walk only on empty returns: AAC framing routinely
      // shaves a few hundred samples off full chunks, so a length
      // threshold would stop after the first chunk.
      if (mono.isEmpty) break;
    }
    sw.stop();
    lastRealtimeFactor = audioSecs > 0
        ? audioSecs / (sw.elapsedMilliseconds / 1000.0)
        : -1;
    return out;
  }

  /// Model input tensor layout [1][80][3000]: batch, mels, time.
  /// Pure — unit-tested. (An earlier revision fed [1][3000][80]; same
  /// element count, so no shape error — just silently transposed audio.)
  static List<List<List<double>>> buildInput(List<List<double>> window) {
    return [
      [
        for (var m = 0; m < WhisperMel.nMels; m++)
          [for (var t = 0; t < WhisperMel.chunkFrames; t++) window[t][m]],
      ],
    ];
  }

  /// Streaming twin of [transcribe]: identical segments, but mel +
  /// inference run in a background isolate so the UI (and its progress
  /// dialog) stays alive — no ANR on multi-minute videos. Extraction and
  /// DB-adjacent bookkeeping stay on main (channels + sqflite are main
  /// isolate only). Falls back to [transcribe] when the worker cannot
  /// spawn (slow UI, functional).
  @override
  Future<List<SpeechSegment>> transcribeStream(
    MediaEntry entry, {
    void Function(int chunk, double startSecs)? onChunk,
  }) async {
    final path = localPathFor(entry.uri);
    if (path == null) return const [];
    // Stage assets where the worker can read them without channels.
    String modelPath;
    String vocabJson;
    try {
      final data = await rootBundle.load(modelAsset);
      final dir = await getTemporaryDirectory();
      final staged = File('${dir.path}/whisper_tiny.tflite');
      if (!await staged.exists()) {
        await staged.writeAsBytes(
          data.buffer.asUint8List(),
          flush: true,
        );
      }
      modelPath = staged.path;
      vocabJson = await rootBundle.loadString(vocabAsset);
    } catch (_) {
      return const [];
    }
    final spawned = await WhisperWorker.spawn(
      modelPath: modelPath,
      vocabJson: vocabJson,
      threads: numThreads,
    );
    if (spawned == null) return transcribe(entry);
    final worker = spawned.worker;
    try {
      final sw = Stopwatch()..start();
      final out = <SpeechSegment>[];
      lastChunkInfo.clear();
      var audioSecs = 0.0;
      for (var chunk = 0; chunk < 20; chunk++) {
        final start = chunk * 30.0;
        onChunk?.call(chunk, start);
        final raw = await AudioExtractor.extractPcm(
          path,
          startSec: start,
          durSec: 30.0,
        );
        if (raw == null || raw.pcm.isEmpty) break;
        lastExtVersion = raw.ext;
        final byteLen = raw.pcm.lengthInBytes;
        final reply = await worker.inferChunk(
          rawPcm: raw.pcm,
          sampleRate: raw.sampleRate,
          channels: raw.channels,
          encoding: raw.encoding,
          startSecs: start,
        );
        if (reply['error'] != null) {
          lastError = 'worker: ${reply['error']}';
          break;
        }
        audioSecs += (reply['audioSecs'] as num?)?.toDouble() ?? 0.0;
        final rms = (reply['rms'] as num?)?.toDouble() ?? 0.0;
        final peak = (reply['peak'] as num?)?.toDouble() ?? 0.0;
        final nanCount = (reply['nan'] as num?)?.toInt() ?? 0;
        final melMean = (reply['melMean'] as num?)?.toDouble() ?? 0.0;
        final melStd = (reply['melStd'] as num?)?.toDouble() ?? 0.0;
        final enc = reply['enc'] as String? ?? '?';
        final ids = (reply['ids'] as List?)?.toList() ?? const [];
        final segs = reply['segs'] as List? ?? const [];
        if (lastChunkInfo.length < 6) {
          lastChunkInfo.add(
            'c$chunk bytes=$byteLen enc=$enc '
            'rms=${rms.toStringAsFixed(4)} peak=${peak.toStringAsFixed(3)} '
            'nan=$nanCount mel=${melMean.toStringAsFixed(3)}/'
            '${melStd.toStringAsFixed(3)} '
            'ids=[${ids.take(10).join(',')}] segs=${segs.length}',
          );
        }
        for (final s in segs) {
          final m = Map<String, Object?>.from(s as Map);
          out.add(
            SpeechSegment(
              tStart: (m['s'] as num).toDouble(),
              tEnd: (m['e'] as num).toDouble(),
              text: m['t'] as String,
            ),
          );
        }
        // Empty returns already break the loop at the top (raw null or
        // empty pcm), matching transcribe().
      }
      sw.stop();
      lastRealtimeFactor = audioSecs > 0
          ? audioSecs / (sw.elapsedMilliseconds / 1000.0)
          : -1;
      return out;
    } finally {
      worker.close();
    }
  }

  /// Native extractor build fingerprint from the last run (0 = the
  /// pre-versioned extractor that never reported one).
  int lastExtVersion = 0;

  /// Per-chunk debug lines (PCM stats + raw head ids + segment count).
  /// Surfaced by the Transcribe test video dialog; cap keeps it small.
  final List<String> lastChunkInfo = [];

  List<int> _run(List<List<double>> window) {
    final interp = _interp!;
    try {
      final d1 = _outShape.length > 1 ? _outShape[1] : 448;
      final output = [List<int>.filled(d1, 0)];
      interp.run(buildInput(window), output);
      return output[0];
    } catch (e, st) {
      lastError = 'invoke: $e';
      lastStack = '$st';
      throw StateError('whisper invoke failed: $e');
    }
  }
}
