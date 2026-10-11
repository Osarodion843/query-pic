import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/media_source.dart';
import 'package:querypic/services/mel.dart';
import 'package:querypic/services/stt_indexer.dart';
import 'package:querypic/services/tflite_stt.dart';
import 'package:querypic/services/whisper_decoder.dart';
import 'package:querypic/services/whisper_vocab.dart';

/// Pure-logic tests for the Step 5 real-STT stack (host-runnable).
/// Model inference itself runs on device (tflite_flutter); everything
/// around it — frontend, vocab, decoder, gating — is proven here.
void main() {
  group('WhisperMel', () {
    test('silence maps to the feature floor', () {
      final frames = WhisperMel.compute(List<double>.filled(16000, 0));
      expect(frames.length, 100);
      expect(frames.first.length, WhisperMel.nMels);
      for (final row in frames) {
        for (final v in row) {
          expect(v, closeTo(-1.5, 1e-6));
        }
      }
    });

    test('a 440 Hz tone produces energy above the floor', () {
      final pcm = List<double>.generate(
        16000,
        (i) => 0.5 * math.sin(2 * math.pi * 440 * i / 16000),
      );
      final frames = WhisperMel.compute(pcm);
      var peak = -1e30;
      for (final row in frames) {
        for (final v in row) {
          if (v > peak) peak = v;
        }
      }
      expect(peak, greaterThan(0.0));
    });

    test('440 Hz energy lands in the expected mel bands', () {
      // 440 Hz -> 6.6 mel -> band ~11 of 80; leakage-tolerant window.
      final pcm = List<double>.generate(
        16000,
        (i) => 0.5 * math.sin(2 * math.pi * 440 * i / 16000),
      );
      final frames = WhisperMel.compute(pcm);
      final mean =
          List<double>.filled(WhisperMel.nMels, 0.0);
      for (final row in frames) {
        for (var m = 0; m < WhisperMel.nMels; m++) {
          mean[m] += row[m] / frames.length;
        }
      }
      var argmax = 0;
      for (var m = 1; m < mean.length; m++) {
        if (mean[m] > mean[argmax]) argmax = m;
      }
      expect(argmax, inInclusiveRange(5, 20));
    });

    test('chunkWindow pads and trims to 3000 frames', () {
      final short = List<List<double>>.generate(
        100,
        (_) => List<double>.filled(WhisperMel.nMels, 0.0),
      );
      expect(WhisperMel.chunkWindow(short).length, 3000);
      final long = List<List<double>>.generate(
        4000,
        (_) => List<double>.filled(WhisperMel.nMels, 0.0),
      );
      expect(WhisperMel.chunkWindow(long).length, 3000);
    });
  });

  group('WhisperVocab', () {
    const mini = '{"hello": 0, "Ġworld": 1, "!": 2}';

    test('parses id map and detokenizes GPT-2 bytes', () {
      final vocab = WhisperVocab.parse(mini);
      expect(vocab.detokenize([0, 1, 2]), 'hello world!');
    });

    test('byte encoder maps space to Ġ', () {
      expect(WhisperVocab.byteEncoder()[32], 'Ġ');
    });

    test('timestamp helpers follow the whisper layout', () {
      expect(WhisperVocab.eot, 50257);
      expect(WhisperVocab.isTimestamp(50364), isTrue);
      expect(WhisperVocab.isTimestamp(50257), isFalse);
      expect(WhisperVocab.timestampSecs(50464), closeTo(2.0, 1e-9));
    });
  });

  group('decodeWhisperSegments', () {
    late WhisperVocab vocab;
    setUp(() {
      vocab = WhisperVocab.parse('{"hello": 0, "Ġworld": 1}');
    });

    test('timestamp pairs delimit segments', () {
      final segs = decodeWhisperSegments([50364, 0, 1, 50464], vocab);
      expect(segs.length, 1);
      expect(segs.first.start, 0);
      expect(segs.first.end, closeTo(2.0, 1e-9));
      expect(segs.first.text, 'hello world');
    });

    test('eot stops decoding, trailing text is capped', () {
      final segs = decodeWhisperSegments([50364, 0, 50257, 1, 50464], vocab);
      expect(segs.length, 1);
      expect(segs.first.text, 'hello');
    });

    test('no timestamps means one chunk-long segment', () {
      final segs = decodeWhisperSegments(
        [0, 1],
        vocab,
        chunkOffsetSecs: 30,
        chunkDurSecs: 30,
      );
      expect(segs.length, 1);
      expect(segs.first.start, 30);
      expect(segs.first.end, 60);
    });

    test('non-timestamp specials are skipped', () {
      final segs = decodeWhisperSegments([50358, 0], vocab);
      expect(segs.length, 1);
      expect(segs.first.text, 'hello');
    });

    test('chunk offset shifts timestamps', () {
      final segs = decodeWhisperSegments(
        [50364, 0, 50464],
        vocab,
        chunkOffsetSecs: 30,
      );
      expect(segs.first.start, 30);
      expect(segs.first.end, closeTo(32.0, 1e-9));
    });

    test('leading eot skipped, padding tail trimmed', () {      // Mirrors the real TFLite output layout: start marker, text with
      // timestamps, end marker, zero padding.
      final segs = decodeWhisperSegments(
        [50257, 50363, 0, 1, 50464, 50257, 0, 0, 0, 0, 0, 0, 0, 0],
        vocab,
      );
      expect(segs.length, 1);
      expect(segs.first.text, 'hello world');
      expect(segs.first.start, 0);
      expect(segs.first.end, closeTo(2.0, 1e-9));
    });
  });

  group('TfliteSttEngine', () {
    test('missing assets fail closed to empty segments', () async {
      final engine = TfliteSttEngine(
        modelAsset: 'nope/missing.tflite',
        vocabAsset: 'nope/missing.json',
      );
      expect(await engine.load(), isFalse);
      expect(
        await engine.transcribe(
          const MediaEntry(
            uri: 'file:///sdcard/Download/x.mp4',
            isVideo: true,
            mtimeMillis: 0,
            sizeBytes: 0,
          ),
        ),
        isEmpty,
      );
    });

    test('transcribeStream fails closed without assets (no worker)', () async {
      // Staging rootBundle assets is impossible off-device, so the
      // streamed path must degrade to empty exactly like transcribe().
      final engine = TfliteSttEngine(
        modelAsset: 'nope/missing.tflite',
        vocabAsset: 'nope/missing.json',
      );
      expect(
        await engine.transcribeStream(
          const MediaEntry(
            uri: 'file:///sdcard/Download/x.mp4',
            isVideo: true,
            mtimeMillis: 0,
            sizeBytes: 0,
          ),
        ),
        isEmpty,
      );
    });

    test('stub engine streams identically to transcribe (default)', () async {
      const engine = StubSttEngine();
      const entry = MediaEntry(
        uri: 'demo://sample-videos/birthday_party.mp4',
        isVideo: true,
        mtimeMillis: 0,
        sizeBytes: 0,
      );
      expect(
        await engine.transcribeStream(entry),
        hasLength((await engine.transcribe(entry)).length),
      );
    });

    test('buildInput lays out [1][80][3000] batch/mels/time', () {
      final window = List<List<double>>.generate(
        3000,
        (t) => List<double>.generate(80, (m) => t * 1000.0 + m),
      );
      final input = TfliteSttEngine.buildInput(window);
      expect(input.length, 1);
      expect(input[0].length, 80);
      expect(input[0][0].length, 3000);
      // Spot check: input[0][m][t] == window[t][m].
      expect(input[0][7][123], 123 * 1000.0 + 7);
      expect(input[0][0][0], 0.0);
      expect(input[0][79][2999], 2999 * 1000.0 + 79);
    });

    test('sanitizePcm replaces non-finite samples, counts them', () {
      final pcm = Float32List.fromList(
        [0.5, double.nan, -0.25, double.infinity, 0.0],
      );
      final cleaned = TfliteSttEngine.sanitizePcm(pcm);
      expect(cleaned.$2, 2);
      expect(cleaned.$1.toList(), [0.5, 0.0, -0.25, 0.0, 0.0]);
      // Never mutates: channel-provided views are unmodifiable.
      final frozen = List<double>.unmodifiable([0.25, double.nan]);
      final cleaned2 = TfliteSttEngine.sanitizePcm(frozen);
      expect(cleaned2.$2, 1);
      expect(cleaned2.$1.toList(), [0.25, 0.0]);
      final input = [0.5, -0.25];
      final clean = TfliteSttEngine.sanitizePcm(input);
      expect(clean.$2, 0);
      expect(identical(clean.$1, input), isTrue);
    });

    test('localPathFor admits files, rejects the rest', () {      expect(
        TfliteSttEngine.localPathFor('file:///sdcard/Download/x.mp4'),
        '/sdcard/Download/x.mp4',
      );
      expect(
        TfliteSttEngine.localPathFor('/sdcard/Download/x.mp4'),
        '/sdcard/Download/x.mp4',
      );
      expect(TfliteSttEngine.localPathFor('demo://sample-videos/a.mp4'),
          isNull,);
      expect(TfliteSttEngine.localPathFor('content://media/1'), isNull);
      expect(TfliteSttEngine.localPathFor('https://x/y.mp4'), isNull);
    });
  });

  group('filterHallucinations', () {
    ({double start, double end, String text}) seg(String text) =>
        (start: 0, end: 1, text: text);

    test('drops the real on-device repetition loop', () {
      // Verbatim device output (whisper loop over music/silence).
      final loop = '我们在我们的国附近宜测中' * 12;
      final out = filterHallucinations([seg(loop), seg('Hello world')]);
      expect(out.length, 1);
      expect(out.single.text, 'Hello world');
    });

    test('drops non-Latin-majority segments', () {
      final out = filterHallucinations(
        [seg('我無論如何我無論如何我無論如何我無論如何我無論如何我無論如何')],
      );
      expect(out, isEmpty);
    });

    test('drops variant loops with mutations and truncation', () {
      // Observed shape: mostly-exact repeats with a mid-string variant
      // and a cut-off tail — exact-prefix matching misses these.
      final loop =
          '${'我们在我们的国附近宜测中,' * 5}附近定中,${'我们在我们的国附近宜测中,' * 5}';
      final out = filterHallucinations([seg(loop), seg('Hello world')]);
      expect(out.length, 1);
      expect(out.single.text, 'Hello world');
    });

    test('keeps mixed text with a CJK fragment', () {
      // A stray non-English fragment inside mostly-English text is not
      // a loop and not a majority — kept as transcribed.
      const t = 'Hello world this is a test 世界 hello again here today';
      final out = filterHallucinations([seg(t)]);
      expect(out.length, 1);
    });

    test('keeps genuine English, accents, and short repeats', () {
      final keep = [
        'Hello world. This is a test.',
        'Café naïve résumé', // accented Latin stays Latin
        'ha ha ha', // short genuine repetition survives the bar
        'user-first approach and not a tech-first approach',
      ];
      final out = filterHallucinations(
        [for (final t in keep) seg(t)],
      );
      expect(out.map((s) => s.text), keep);
    });
  });
}
