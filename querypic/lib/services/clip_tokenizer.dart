import 'dart:convert';

import 'package:flutter/services.dart';

/// CLIP word-level BPE tokenizer (Step 5).
///
/// Matches the on-disk `vocab.json` (token -> id) + `merges.txt` pair:
/// HuggingFace-style BPE with `</w>` end-of-word suffix, lowercased input,
/// `<|startoftext|>` prefix and `<|endoftext|>` suffix, padded with EOT to
/// the 77-token CLIP context. Pure Dart — host-testable without TFLite.
class ClipTokenizer {
  static const contextLength = 77;
  static const sotId = 49406;
  static const eotId = 49407;
  static const padId = eotId; // CLIP pads with EOT.
  static const _eow = '</w>';

  final Map<String, int> vocab;
  final Map<String, int> ranks; // "a b" -> merge rank (lower = earlier).

  const ClipTokenizer({required this.vocab, required this.ranks});

  /// Parse the on-disk pair. `merges.txt` starts with a `#version:` header
  /// line which is skipped; every other non-empty line is one ranked pair.
  factory ClipTokenizer.fromMaps(
    Map<String, dynamic> vocabJson,
    String mergesTxt,
  ) {
    final vocab = <String, int>{};
    vocabJson.forEach((k, v) => vocab[k] = (v as num).toInt());
    final ranks = <String, int>{};
    var rank = 0;
    for (final line in const LineSplitter().convert(mergesTxt)) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      ranks[t] = rank++;
    }
    return ClipTokenizer(vocab: vocab, ranks: ranks);
  }

  /// Load the bundled pair (see pubspec assets).
  static Future<ClipTokenizer> loadDefault() async {
    final vocabJson = json.decode(
      await rootBundle.loadString('sandbox/models/vocab.json'),
    ) as Map<String, dynamic>;
    final merges =
        await rootBundle.loadString('sandbox/models/merges.txt');
    return ClipTokenizer.fromMaps(vocabJson, merges);
  }

  /// Encode to exactly [contextLength] ids for the text tower.
  List<int> encode(String text) {    final ids = <int>[sotId];
    for (final word in text.toLowerCase().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      ids.addAll(_encodeWord(word));
      if (ids.length >= contextLength - 1) break;
    }
    ids.add(eotId);
    while (ids.length < contextLength) {
      ids.add(padId);
    }
    return ids.sublist(0, contextLength);
  }

  /// EOT position for the joint model's third input: first EOT id at
  /// index>=1 (real words never emit it). Falls back to the last slot.
  static int eotPosition(List<int> ids) {
    for (var i = 1; i < ids.length; i++) {
      if (ids[i] == eotId) return i;
    }
    return ids.length - 1;
  }

  List<int> _encodeWord(String word) {
    final suffixed = '$word$_eow';
    if (vocab.containsKey(suffixed)) return [vocab[suffixed]!];
    var parts = _charsWithEow(word);
    while (true) {
      final pairs = _pairs(parts);
      var bestRank = 1 << 30;
      String? bestFirst;
      String? bestSecond;
      for (var i = 0; i < pairs.length; i += 2) {
        final key = '${pairs[i]} ${pairs[i + 1]}';
        final r = ranks[key];
        if (r != null && r < bestRank) {
          bestRank = r;
          bestFirst = pairs[i];
          bestSecond = pairs[i + 1];
        }
      }
      if (bestFirst == null || bestSecond == null) break;
      parts = _merge(parts, bestFirst, bestSecond);
      if (parts.length == 1) break;
    }
    final out = <int>[];
    for (final p in parts) {
      final id = vocab[p];
      if (id != null) out.add(id);
      // Missing pieces are skipped (full single-char coverage in the
      // shipped vocab makes this unreachable in practice).
    }
    return out;
  }

  static List<String> _charsWithEow(String word) {
    final chars = word.split('');
    chars[chars.length - 1] = '${chars.last}$_eow';
    return chars;
  }

  static List<String> _pairs(List<String> parts) {
    final out = <String>[];
    for (var i = 0; i < parts.length - 1; i++) {
      out.add(parts[i]);
      out.add(parts[i + 1]);
    }
    return out;
  }

  static List<String> _merge(
    List<String> parts,
    String first,
    String second,
  ) {
    final out = <String>[];
    var i = 0;
    while (i < parts.length) {
      if (i < parts.length - 1 &&
          parts[i] == first &&
          parts[i + 1] == second) {
        out.add('$first$second');
        i += 2;
      } else {
        out.add(parts[i]);
        i++;
      }
    }
    return out;
  }
}
