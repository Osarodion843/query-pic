import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import 'mel.dart';
import 'resample.dart';
import 'tflite_stt.dart';
import 'whisper_decoder.dart';
import 'whisper_vocab.dart';

/// Whisper inference on a background isolate (ANR fix).
///
/// Root cause of the "isn't responding" dialog: `Interpreter.run` is a
/// synchronous native call holding the UI thread for tens of seconds per
/// 30 s audio chunk (minutes per video on debug builds). This worker owns
/// a second interpreter inside a spawned isolate: the main isolate only
/// ever does fast async work (MediaCodec extraction, message passing, DB
/// writes), so the UI, progress dialog, and banner stay alive throughout.
///
/// Split of labor per chunk:
///   main isolate: extractPcm (native, async) -> ship RAW decoder bytes
///   worker isolate: decodeMono -> resample16k -> sanitize -> pad -> mel
///     -> chunkWindow -> inference -> timestamp decode -> segment maps
///   main isolate: stats (chunkInfo parity) -> indexSegments (DB)
///
/// All messages are transferables (bytes, numbers, plain maps) — no model
/// handles or closures cross the boundary. The worker loads its own
/// interpreter from a FILE path (asset bytes are staged to cache by the
/// caller: background isolates must not touch rootBundle/channels).
/// Any spawn/load failure surfaces as an error reply, and callers fall
/// back to in-thread transcribe (slow UI, but functional).
class WhisperWorker {
  final Isolate _isolate;
  final Completer<SendPort> _portReady = Completer<SendPort>();
  int _nextId = 0;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  late final StreamSubscription _sub;
  bool _closed = false;

  WhisperWorker._(this._isolate, ReceivePort receive) {
    _sub = receive.listen((message) {
      if (message is! Map) return;
      final map = Map<String, Object?>.from(message);
      // Worker handshake carries its SendPort (NOT a call reply).
      if (map.containsKey('port') && !_portReady.isCompleted) {
        _portReady.complete(map['port'] as SendPort);
        return;
      }
      final id = (map['id'] as num?)?.toInt();
      if (id == null) return;
      final c = _pending.remove(id);
      c?.complete(map);
    });
  }

  /// Spawn + load. Returns null when the worker cannot run (caller falls
  /// back). [outShape] is read back from the loaded graph.
  static Future<({WhisperWorker worker, List<int> outShape})?> spawn({
    required String modelPath,
    required String vocabJson,
    required int threads,
  }) async {
    try {
      final receive = ReceivePort();
      final isolate = await Isolate.spawn(
        _entry,
        receive.sendPort,
        debugName: 'whisper-stt',
      );
      final worker = WhisperWorker._(isolate, receive);
      final reply = await worker._call({
        'cmd': 'load',
        'modelPath': modelPath,
        'vocabJson': vocabJson,
        'threads': threads,
      });
      if (reply['error'] != null) {
        worker.close();
        return null;
      }
      final shape = (reply['outShape'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [1, 448];
      return (worker: worker, outShape: shape);
    } catch (_) {
      return null;
    }
  }

  /// Run one 30 s chunk: [rawPcm] decoder bytes + format meta.
  /// Returns segment maps plus the chunk diagnostics the debug dialog
  /// prints (rms/peak/nan/mel/ids parity with the in-thread path).
  Future<Map<String, Object?>> inferChunk({
    required Uint8List rawPcm,
    required int sampleRate,
    required int channels,
    required int encoding,
    required double startSecs,
  }) {
    return _call({
      'cmd': 'infer',
      'pcm': rawPcm,
      'sampleRate': sampleRate,
      'channels': channels,
      'encoding': encoding,
      'start': startSecs,
    });
  }

  Future<Map<String, Object?>> _call(Map<String, Object?> message) async {
    if (_closed) return {'error': 'closed'};
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    try {
      final port = await _portReady.future;
      port.send({...message, 'id': id});
    } catch (_) {
      _pending.remove(id);
      return {'error': 'send failed'};
    }
    return c.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_portReady.isCompleted) {
      try {
        _portReady.future.then((port) => port.send({'cmd': 'close'}));
      } catch (_) {}
    }
    _sub.cancel();
    _isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> _entry(SendPort mainSend) async {
  final receive = ReceivePort();
  mainSend.send({'id': -1, 'port': receive.sendPort});
  Interpreter? interp;
  WhisperVocab? vocab;
  List<int> outShape = const [1, 448];

  await for (final raw in receive) {
    if (raw is! Map) continue;
    final message = Map<String, Object?>.from(raw);
    final id = (message['id'] as num?)?.toInt() ?? -2;
    void reply(Map<String, Object?> body) =>
        mainSend.send({'id': id, ...body});
    final cmd = message['cmd'] as String?;
    try {
      if (cmd == 'load') {
        final options = InterpreterOptions()
          ..threads = (message['threads'] as num?)?.toInt() ?? 4;
        interp = Interpreter.fromFile(
          File(message['modelPath'] as String),
          options: options,
        );
        final shape = interp.getOutputTensor(0).shape;
        if (shape.length == 2) outShape = shape;
        vocab = WhisperVocab.parse(message['vocabJson'] as String);
        reply({'outShape': outShape});
      } else if (cmd == 'infer') {
        final result = _runChunk(
          interp!,
          vocab!,
          outShape,
          message['pcm'] as Uint8List,
          (message['sampleRate'] as num).toInt(),
          (message['channels'] as num).toInt(),
          (message['encoding'] as num).toInt(),
          (message['start'] as num).toDouble(),
        );
        reply(result);
      } else if (cmd == 'close') {
        try {
          interp?.close();
        } catch (_) {}
        receive.close();
        return;
      } else {
        reply({'error': 'unknown cmd'});
      }
    } catch (e) {
      reply({'error': '$e'});
    }
  }
}

/// One 30 s chunk, worker side. Mirrors TfliteSttEngine.transcribe's chunk
/// body exactly (same math, same floor values) minus UI concerns.
Map<String, Object?> _runChunk(
  Interpreter interp,
  WhisperVocab vocab,
  List<int> outShape,
  Uint8List rawPcm,
  int sampleRate,
  int channels,
  int encoding,
  double startSecs,
) {
  final decoded = Pcm.decodeMono(
    rawPcm,
    channels: channels,
    encoding: encoding,
  );
  var mono = Resampler.resample16k(decoded.mono, sampleRate);
  final audioSecs = mono.length / 16000.0;
  final cleaned = TfliteSttEngine.sanitizePcm(mono);
  var samples = cleaned.$1;
  const need = 30 * 16000;
  if (samples.length < need) {
    samples = [
      ...samples,
      ...List<double>.filled(need - samples.length, 0.0),
    ];
  }
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
  var melN = 0;
  for (final row in mel) {
    for (final v in row) {
      melMean += v;
      melN++;
    }
  }
  melMean = melN == 0 ? 0.0 : melMean / melN;
  var melVar = 0.0;
  for (final row in mel) {
    for (final v in row) {
      final d = v - melMean;
      melVar += d * d;
    }
  }
  final melStd = melN == 0 ? 0.0 : math.sqrt(melVar / melN);
  final window = WhisperMel.chunkWindow(mel);
  final d1 = outShape.length > 1 ? outShape[1] : 448;
  final output = [List<int>.filled(d1, 0)];
  interp.run(TfliteSttEngine.buildInput(window), output);
  final seqs = output[0];
  final segs = decodeWhisperSegments(seqs, vocab, chunkOffsetSecs: startSecs);
  return {
    'audioSecs': audioSecs,
    'rms': rms,
    'peak': peak,
    'nan': cleaned.$2,
    'melMean': melMean,
    'melStd': melStd,
    'enc': decoded.encodingUsed,
    'ids': seqs.take(10).toList(),
    'segs': [
      for (final s in segs) {'s': s.start, 'e': s.end, 't': s.text},
    ],
  };
}
