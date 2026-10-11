import 'dart:convert';

/// Whisper BPE vocabulary (Phase 5 STT wiring).
/// Loads whisper_vocab.json (GPT-2 ranks + endoftext; Whisper special ids
/// above 50257 are handled arithmetically by the decoder, never looked up).
/// Detokenization follows GPT-2 byte-level BPE via bytes_to_unicode.
class WhisperVocab {
  final Map<int, String> idToToken;
  WhisperVocab(this.idToToken);

  static WhisperVocab parse(String jsonStr) {
    final m = json.decode(jsonStr) as Map<String, dynamic>;
    return WhisperVocab(
      {for (final e in m.entries) (e.value as int): e.key},
    );
  }

  static int get eot => 50257;
  static int get timestampBegin => 50364;
  static double get timestampResolution => 0.02;

  static bool isTimestamp(int id) => id >= timestampBegin;

  static double timestampSecs(int id) =>
      (id - timestampBegin) * timestampResolution;

  /// GPT-2 bytes_to_unicode table (byte value -> single char).
  static Map<int, String> byteEncoder() {
    final bs = <int>[
      ...List<int>.generate(94, (i) => i + 33),
      ...List<int>.generate(12, (i) => i + 161),
      ...List<int>.generate(82, (i) => i + 174),
    ];
    final cs = List<int>.from(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    return {
      for (var i = 0; i < bs.length; i++)
        bs[i]: String.fromCharCode(cs[i]),
    };
  }

  static Map<String, int> _byteDecoder() {
    final enc = byteEncoder();
    return {for (final e in enc.entries) e.value: e.key};
  }

  /// Detokenize regular token ids to text. Unknown ids are skipped;
  /// timestamp/special ids must be filtered by the caller.
  String detokenize(List<int> ids) {
    final decoder = _byteDecoder();
    final text = ids.map((id) => idToToken[id] ?? '').join();
    final bytes = <int>[];
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final b = decoder[ch];
      if (b != null) bytes.add(b);
    }
    try {
      return utf8.decode(bytes, allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }
}
