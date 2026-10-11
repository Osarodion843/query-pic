import 'whisper_vocab.dart';

/// Timestamp-token segment decoder (Phase 5 STT wiring).
/// Pure — unit-tested with fixtures. Splits a generated id sequence on
/// Whisper timestamp pairs (<|t0|> text <|t1|>) into timed segments;
/// text without timestamps becomes one chunk-long segment.
///
/// Two quirks of the baked TFLite output this handles explicitly:
/// - a LEADING 50257 is the converter's generation-start marker, not
///   end-of-text: it is skipped unless content was already emitted, in
///   which case it terminates the sequence;
/// - slots past the generated prefix keep our zero-filled buffer, so a
///   run of 8+ zero ids ends decoding and trailing '!'s (id 0) are
///   trimmed from the final segment only.
///
/// Hallucination loops (repetition traps on music/silence, wrong-script
/// output from the multilingual model) are filtered post-hoc — the
/// baked graph exposes no temperature/penalty knobs, so this is the
/// portable equivalent of whisper's compression-ratio + logprob
/// fallbacks (plus a script gate VAD-lite cannot provide).
List<({double start, double end, String text})> decodeWhisperSegments(
  List<int> ids,
  WhisperVocab vocab, {
  double chunkOffsetSecs = 0,
  double chunkDurSecs = 30.0,
}) {
  final out = <({double start, double end, String text})>[];
  var buf = <int>[];
  double? segStart;
  var sawTimestamp = false;
  var zeroRun = 0;
  var terminated = false;

  void flush(double end) {
    final text = vocab.detokenize(buf);
    buf = <int>[];
    if (text.isEmpty) {
      segStart = end;
      return;
    }
    out.add((
      start: (segStart ?? 0) + chunkOffsetSecs,
      end: end + chunkOffsetSecs,
      text: text,
    ),);
    segStart = end;
  }

  for (final id in ids) {
    if (id == 0) {
      zeroRun++;
      buf.add(id);
      if (zeroRun >= 8) {
        terminated = true;
        break;
      }
      continue;
    }
    zeroRun = 0;
    if (id == WhisperVocab.eot) {
      if (buf.isNotEmpty || out.isNotEmpty) {
        terminated = true;
        break;
      }
      continue;
    }
    if (WhisperVocab.isTimestamp(id)) {
      sawTimestamp = true;
      final t = WhisperVocab.timestampSecs(id);
      if (buf.isNotEmpty) {
        flush(t);
      } else {
        segStart = t;
      }
      continue;
    }
    if (id >= 50258) continue; // other specials (sot/task/lang/nospeech)
    buf.add(id);
  }
  if (buf.isNotEmpty) {
    if (!sawTimestamp && out.isEmpty && !terminated) {
      final text = vocab.detokenize(buf);
      if (text.isNotEmpty) {
        out.add((
          start: chunkOffsetSecs,
          end: chunkOffsetSecs + chunkDurSecs,
          text: text,
        ),);
      }
      return filterHallucinations(out);
    }
    // Trailing text: trim zero-padding artifacts, cap the run.
    var text = vocab.detokenize(buf);
    text = text.replaceAll(RegExp(r'!+$'), '');
    if (text.isNotEmpty) {
      final end = (segStart ?? 0) + buf.length * 0.24;
      out.add((
        start: (segStart ?? 0) + chunkOffsetSecs,
        end: (end > chunkDurSecs ? chunkDurSecs : end) + chunkOffsetSecs,
        text: text,
      ),);
    }
  }
  return filterHallucinations(out);
}

/// Drop hallucinated segments (whisper-fallback equivalent for baked
/// graphs): repetition loops (token-probability traps over music or
/// silence) and non-Latin-majority text (multilingual model
/// hallucinating other scripts). Pure — tested with real on-device
/// loops, including variant loops with mid-string mutations and
/// truncated tails. Genuine short repetitions ("ha ha ha") survive:
/// detection keys on 8-gram vocabulary richness, which stays near 1.0
/// for natural text of any language.
List<({double start, double end, String text})> filterHallucinations(
  List<({double start, double end, String text})> segs,
) {
  bool isLoop(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), '');
    if (t.length < 10) return false;
    final uniq = t.split('').toSet().length;
    if (uniq / t.length < 0.08) return true;
    if (t.length >= 24) {
      final seen = <String>{};
      var total = 0;
      for (var i = 0; i + 8 <= t.length; i++) {
        seen.add(t.substring(i, i + 8));
        total++;
      }
      // A 12-char unit repeated exactly has 12 distinct 8-grams in
      // hundreds of windows (~0.03); natural text sits near 1.0.
      // Single-char mutations only add a handful of new 8-grams, so
      // variant loops still score far below the bar.
      if (seen.length / total < 0.25) return true;
    }
    return false;
  }

  bool isNonLatinMajority(String text) {
    var latin = 0;
    var total = 0;
    for (final r in text.runes) {
      if (r <= 0x20 || (r >= 0x7F && r <= 0x9F)) continue;
      total++;
      if ((r >= 0x30 && r <= 0x39) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A) ||
          (r >= 0xC0 && r <= 0x2AF) ||
          '.,!?;:\'"-–—()'.contains(String.fromCharCode(r))) {
        latin++;
      }
    }
    if (total == 0) return false;
    return latin / total < 0.5;
  }

  return [
    for (final s in segs)
      if (!isLoop(s.text) && !isNonLatinMajority(s.text)) s,
  ];
}
