import 'index_database.dart';

/// Score bands for match badges (DESIGN_SYSTEM.md).
/// Color is never the only signal — the % number always renders too.
enum ScoreBand { high, mid, low }
ScoreBand bandFor(int score) {
  if (score >= 80) return ScoreBand.high;
  if (score >= 50) return ScoreBand.mid;
  return ScoreBand.low;
}

/// Free-tier date filter parsed from natural query keywords (Phase 3, task 2).
/// Phase 5 fuzzy-temporal ("last summer", "recent") sets [fuzzy] and is
/// Pro-gated — see resolveFilter in pro_gate.dart. Anything unparsed means
/// "no date constraint".
class DateFilter {
  final int? fromMillis;
  final int? toMillis;
  final String? label;

  /// True when fuzzy-temporal keywords (Pro) produced this filter.
  final bool fuzzy;
  const DateFilter(
      {this.fromMillis, this.toMillis, this.label, this.fuzzy = false,});

  bool get isActive => fromMillis != null || toMillis != null;

  bool admits(int mtimeMillis) {
    if (fromMillis != null && mtimeMillis < fromMillis!) return false;
    if (toMillis != null && mtimeMillis > toMillis!) return false;
    return true;
  }
}

/// Keyword date parsing. Pure — unit-tested. `now` is injectable for tests.
DateFilter parseDateFilter(String query, {DateTime? now}) {
  final q = query.toLowerCase();
  final today = now ?? DateTime.now();
  final midnight = DateTime(today.year, today.month, today.day);
  int ms(DateTime d) => d.millisecondsSinceEpoch;

  if (q.contains('today')) {
    return DateFilter(
      fromMillis: ms(midnight),
      label: 'Today',
    );
  }
  if (q.contains('yesterday')) {
    return DateFilter(
      fromMillis: ms(midnight.subtract(const Duration(days: 1))),
      toMillis: ms(midnight) - 1,
      label: 'Yesterday',
    );
  }
  if (q.contains('last week') || q.contains('this week')) {
    return DateFilter(
      fromMillis: ms(midnight.subtract(const Duration(days: 7))),
      label: 'Past week',
    );
  }
  if (q.contains('last month') || q.contains('this month')) {
    return DateFilter(
      fromMillis: ms(DateTime(midnight.year, midnight.month - 1, 1)),
      label: 'Past month',
    );
  }

  // ---- Phase 5 fuzzy-temporal (Pro; fuzzy=true) ----
  if (q.contains('recent')) {
    return DateFilter(
      fromMillis: ms(midnight.subtract(const Duration(days: 30))),
      label: 'Recent',
      fuzzy: true,
    );
  }
  if (q.contains('last year')) {
    return DateFilter(
      fromMillis: ms(midnight.subtract(const Duration(days: 365))),
      label: 'Past year',
      fuzzy: true,
    );
  }
  if (q.contains('this year')) {
    return DateFilter(
      fromMillis: ms(DateTime(midnight.year, 1, 1)),
      label: 'This year',
      fuzzy: true,
    );
  }
  // Seasons use northern-hemisphere meteorological boundaries
  // (spring Mar-May, summer Jun-Aug, autumn Sep-Nov, winter Dec-Feb).
  const seasons = {
    'spring': 3,
    'summer': 6,
    'autumn': 9,
    'fall': 9,
    'winter': 12,
  };
  for (final entry in seasons.entries) {
    final name = entry.key;
    final startMonth = entry.value;
    final capName = '${name[0].toUpperCase()}${name.substring(1)}';
    if (q.contains('last $name')) {
      final (from, to) = _lastSeasonWindow(startMonth, today);
      return DateFilter(
        fromMillis: ms(from),
        toMillis: ms(to),
        label: '$capName ${from.year}',
        fuzzy: true,
      );
    }
    if (q.contains('this $name')) {
      final (from, to) = _thisSeasonWindow(startMonth, today);
      return DateFilter(
        fromMillis: ms(from),
        toMillis: ms(to),
        label: '$capName ${from.year}',
        fuzzy: true,
      );
    }
    if (RegExp('\\b$name\\b').hasMatch(q)) {
      // Bare season word doubles as a token (semantic boost) AND a window.
      final (from, to) = _bareSeasonWindow(startMonth, today);
      return DateFilter(
        fromMillis: ms(from),
        toMillis: ms(to),
        label: '$capName ${from.year}',
        fuzzy: true,
      );
    }
  }
  return const DateFilter();
}

/// Season window starting [startMonth] of [year] (inclusive ms bounds).
(DateTime from, DateTime to) _seasonWindow(int startMonth, int year) {
  final from = DateTime(year, startMonth, 1);
  final endMonth = startMonth == 12 ? 3 : startMonth + 3;
  final endYear = startMonth == 12 ? year + 1 : year;
  final to = DateTime(endYear, endMonth, 1)
      .subtract(const Duration(milliseconds: 1));
  return (from, to);
}

/// Latest season window fully in the past ("last summer").
(DateTime from, DateTime to) _lastSeasonWindow(int startMonth, DateTime now) {
  var year = now.year;
  while (true) {
    final (from, to) = _seasonWindow(startMonth, year);
    if (to.isBefore(now)) return (from, to);
    year--;
  }
}

/// This year's season window, end clamped to now ("this summer").
(DateTime from, DateTime to) _thisSeasonWindow(int startMonth, DateTime now) {
  var (from, to) = _seasonWindow(startMonth, now.year);
  if (from.isAfter(now)) {
    // This year's window hasn't started (e.g. "this winter" in July):
    // fall back to the most recent one.
    (from, to) = _seasonWindow(startMonth, now.year - 1);
  }
  if (to.isAfter(now)) to = now;
  return (from, to);
}

/// Bare season word: current window if inside it, else the last one.
(DateTime from, DateTime to) _bareSeasonWindow(int startMonth, DateTime now) {
  final (from, to) = _seasonWindow(startMonth, now.year);
  if (!now.isBefore(from) && !now.isAfter(to)) {
    return (from, now);
  }
  return _lastSeasonWindow(startMonth, now);
}

class RankedResult {
  final int fileId;
  final String uri;
  final bool isVideo;
  final int mtime;
  final int score;
  final Set<String> matchedVia;

  /// Best matching frame timestamp in seconds (video only, Phase 4+).
  /// Free tier plays from 0s; Phase 5 seeks here.
  final double? bestFrameSecs;

  const RankedResult({
    required this.fileId,
    required this.uri,
    required this.isVideo,
    required this.mtime,
    required this.score,
    required this.matchedVia,
    this.bestFrameSecs,
  });

  ScoreBand get band => bandFor(score);

  RankedResult copyWith({double? bestFrameSecs, int? score}) {
    return RankedResult(
      fileId: fileId,
      uri: uri,
      isVideo: isVideo,
      mtime: mtime,
      score: score ?? this.score,
      matchedVia: matchedVia,
      bestFrameSecs: bestFrameSecs ?? this.bestFrameSecs,
    );
  }
}

/// Score fusion (Phase 3, task 1; Phase 4 frame hits + visual floor).
/// Pure — unit-tested.
///
/// tokenHits: ref_id -> query-token hit count (from tokenSearch).
/// vectorHits: ref_id -> cosine-ish similarity in [-1, 1] (from vectorScan).
/// frameHits: video file_id -> best sampled-frame similarity + timestamp
/// (from frameVectorScan). The frame signal feeds the same 40% visual share
/// as a photo vector; bestFrameSecs is carried on the result for the
/// preview/handoff (Free plays at 0s, Phase 5 seeks here).
/// Weights: 60% text, 40% visual when both signals exist; a lone signal
/// scores on its own scale so single-signal libraries still rank sensibly.
/// visualFloor (0-100): visual-ONLY results below this score are dropped, so
/// gibberish queries don't return random lookalikes. Text-backed results
/// always survive (a token hit is explicit user intent).
/// visualMinSim: lone-visual admission threshold on raw cosine similarity.
/// Stub era (32-d hash vectors) needs 0.9 — only byte-identical vectors pass,
/// since a top-K scan always fills K noise rows at ~0.5-0.7. Real CLIP
/// vectors (512-d) separate genuinely: matches land ~0.25+, random pairs
/// ~0.05-0.15, so 0.25 admits meaning while keeping the clean empty state.
/// Initial device calibration — tune from the Phase 5 dialog's vecTop line.
List<RankedResult> fuseAndRank({
  required Map<int, int> tokenHits,
  required Map<int, double> vectorHits,
  required Map<int, Map<String, Object?>> files,
  Map<int, ({double sim, double t})> frameHits = const {},
  int limit = 50,
  double visualFloor = 0,
  double visualMinSim = 0.9,
}) {
  final maxToken =
      tokenHits.values.fold<int>(0, (a, b) => a > b ? a : b);
  final ids = <int>{...tokenHits.keys, ...vectorHits.keys, ...frameHits.keys};
  final out = <RankedResult>[];
  for (final id in ids) {
    final file = files[id];
    if (file == null) continue;
    final matched = <String>{};
    double score;
    final th = tokenHits[id];
    var vh = vectorHits[id];
    double? bestFrameSecs;
    // Best visual evidence: photo vector vs best video frame. A video may
    // have both (poster-frame embedding + sampled frames) — take the winner.
    final fh = frameHits[id];
    if (fh != null) {
      bestFrameSecs = fh.t;
      if (vh == null || fh.sim > vh) vh = fh.sim;
    }
    if (th != null && vh != null) {
      matched.addAll(['text', 'visual']);
      // 60% text share + 40% visual share, each on a 0-100 scale — but
      // weak visual evidence must never hurt: take the max with the
      // lone-text score, so a noisy frame/vector can't drag a strong
      // text match below text-only rows (device: a 0.099 frame sim
      // dropped a 3/4 text match from 81 to 67, cutting it entirely).
      final blended = 60 * (th / maxToken) + 40 * ((vh + 1) / 2);
      final lone = 55 + 35 * (th / maxToken);
      score = blended > lone ? blended : lone;
    } else if (th != null) {
      matched.add('text');
      // Lone text signal: floor 55, capped at 90. The cap matters: tokenSearch
      // returns LIMIT rows all sharing the max hit count, so an uncapped
      // 55+45*share floods every slot at 100 and crowds out visual/frame
      // evidence that legitimately reaches 100 (exact frame match).
      score = 55 + 35 * (th / maxToken);
    } else {
      matched.add('visual');
      final sim = vh ?? -1;
      // Lone-visual admission gate: a top-K vector scan always fills K rows,
      // even for gibberish. Stub-era noise tails score ~0.5-0.7, so only
      // near-exact stub matches (sim >= 0.9) pass without query text behind
      // them. Real CLIP vectors separate (matches ~0.25+, noise ~0.05-0.15),
      // so the CLIP-era threshold admits meaning instead — see visualMinSim.
      if (tokenHits.isEmpty && sim < visualMinSim) continue;
      score = 100 * (sim + 1) / 2;
    }
    final rounded = score.round().clamp(0, 100);
    // Phase 4 floor: drop lookalikes (visual- or frame-only) with no text
    // behind them. Any token hit is explicit user intent and always survives.
    if (!matched.contains('text') && rounded < visualFloor) {
      continue;
    }
    out.add(
      RankedResult(
        fileId: id,
        uri: file['uri'] as String,
        isVideo: (file['type'] as String) == 'video',
        mtime: (file['mtime'] as int?) ?? 0,
        score: rounded,
        matchedVia: matched,
        bestFrameSecs: bestFrameSecs,
      ),
    );
  }
    // Score desc; on ties a video first (richer result — and video ids are
    // seeded last, so id-only ordering would always cut them in a tie
    // flood); then fileId asc for cross-platform determinism.
    out.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      if (a.isVideo != b.isVideo) return a.isVideo ? -1 : 1;
      return a.fileId.compareTo(b.fileId);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
}

/// Strip date keywords so they don't pollute token matching.
/// Fuzzy scaffolding ("last", "this", "recent") is stripped, but bare
/// season words stay: "summer" is also a semantic token that boosts
/// topical rows (the re-rank half of fuzzy temporal). Word boundaries keep
/// short scaffolding from mangling other words ("thistle", "unrecent").
String stripDateKeywords(String query) {
  var q = query;
  for (final kw in [
    'today',
    'yesterday',
    'recently',
    'recent',
    'last week',
    'this week',
    'last month',
    'this month',
    'last year',
    'this year',
    'last summer',
    'this summer',
    'last winter',
    'this winter',
    'last spring',
    'this spring',
    'last autumn',
    'this autumn',
    'last fall',
    'this fall',
  ]) {
    q = q.replaceAll(RegExp('\\b$kw\\b'), ' ');
  }
  return q.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Shared query preprocessing: date filter + cleaned token query.
({DateFilter filter, String tokens}) prepareQuery(String query,
    {DateTime? now,}) {
  final filter = parseDateFilter(query, now: now);
  final tokens = stripDateKeywords(query);
  return (filter: filter, tokens: tokens);
}

/// Curated query expansion (keyword era): everyday words mapped to the
/// vocabulary ML Kit labels + OCR actually emit. Only ADDS recall —
/// unmatched synonyms match no rows, so they can't dilute scoring
/// (maxToken counts matched rows only).
/// Plain raw words on both sides: keys are stemmed at lookup to meet
/// stemmed query tokens, values flow back through tokenizeForIndex, so
/// both sides reduce identically.
const _synonyms = <String, List<String>>{
  'baby': ['child', 'kid', 'infant'],
  'kid': ['child', 'baby', 'boy', 'girl'],
  'child': ['kid', 'baby', 'boy', 'girl'],
  'dog': ['puppy', 'pet'],
  'cat': ['kitten', 'pet'],
  'pet': ['dog', 'cat', 'bird'],
  'animal': ['pet', 'wildlife', 'dog', 'cat'],
  'bird': ['pet', 'flying', 'animal'],
  'car': ['vehicle', 'automobile', 'road'],
  'food': ['meal', 'dish', 'lunch', 'dinner'],
  'beach': ['ocean', 'sea', 'sand', 'shore'],
  'sunset': ['sunrise', 'dusk', 'dawn', 'sky'],
  'mountain': ['hill', 'peak', 'lake'],
  'city': ['street', 'urban', 'town', 'night'],
  'party': ['celebration', 'birthday', 'wedding'],
  'wedding': ['bride', 'groom', 'marriage', 'party'],
  'vacation': ['travel', 'trip', 'holiday', 'beach'],
  'holiday': ['travel', 'trip', 'vacation'],
  'travel': ['trip', 'vacation', 'tour', 'flight'],
  'selfie': ['person', 'face', 'people'],
  'portrait': ['person', 'face'],
  'people': ['person', 'crowd', 'man', 'woman'],
  'anime': ['cartoon', 'comics', 'poster', 'drawing', 'manga'],
  'cartoon': ['anime', 'comics', 'drawing'],
  'movie': ['cinema', 'film', 'poster'],
  'film': ['movie', 'cinema'],
  'receipt': ['invoice', 'bill', 'payment'],
  'document': ['paper', 'text', 'page', 'scan'],
  'scan': ['document', 'paper', 'text'],
  'screenshot': ['screen', 'phone'],
  'meme': ['funny', 'poster', 'text'],
  'concert': ['stage', 'music', 'performance', 'crowd'],
  'show': ['stage', 'performance'],
  'music': ['concert', 'song', 'dance'],
  'dance': ['music', 'party'],
  'game': ['play', 'sport'],
  'sport': ['game', 'exercise', 'run', 'fitness'],
  'flower': ['garden', 'rose', 'plant'],
  'tree': ['forest', 'wood', 'nature', 'plant'],
  'forest': ['tree', 'nature'],
  'nature': ['outdoor', 'green', 'plant'],
  'garden': ['park', 'plant', 'flower'],
  'park': ['garden', 'green'],
  'snow': ['winter', 'ice', 'cold'],
  'winter': ['snow', 'cold'],
  'rain': ['umbrella', 'wet', 'storm'],
  'sky': ['cloud', 'blue'],
  'water': ['lake', 'river', 'sea', 'ocean'],
  'lake': ['water', 'mountain'],
  'night': ['evening', 'dark', 'city'],
  'boat': ['ship', 'water', 'sailing'],
  'plane': ['flight', 'airport', 'aircraft'],
  'flight': ['plane', 'travel'],
  'train': ['railway', 'travel'],
  'bike': ['bicycle', 'motorcycle', 'ride'],
  'house': ['home', 'building', 'room'],
  'office': ['work', 'meeting', 'laptop', 'computer'],
  'work': ['office', 'job'],
  'school': ['class', 'education', 'student'],
  'church': ['building', 'worship'],
  'cake': ['dessert', 'sweet', 'birthday'],
  'coffee': ['tea', 'cup', 'drink'],
  'gym': ['workout', 'exercise', 'fitness'],
};

/// Stemmed-synonym lookup table, built once (keys stemmed to match
/// stemmed query tokens; values pre-stemmed above).
Map<String, List<String>>? _stemmedSynonyms;
Map<String, List<String>> get _synonymIndex {
  return _stemmedSynonyms ??= {
    for (final e in _synonyms.entries) IndexDatabase.stemToken(e.key): e.value,
  };
}

/// Expand a cleaned query string with synonym recall. The EMBEDDER keeps
/// the raw string — expansion feeds token search only.
String expandQuery(String tokens) {
  final base = IndexDatabase.tokenizeForIndex(tokens);
  if (base.isEmpty) return tokens;
  final out = <String>[tokens];
  for (final t in base) {
    final extra = _synonymIndex[t];
    if (extra == null) continue;
    for (final e in extra) {
      if (!base.contains(e)) out.add(e);
    }
  }
  return out.join(' ');
}

/// Levenshtein distance (rune-safe, capped by early exit). Pure.
int editDistance(String a, String b, {int cap = 3}) {
  final ar = a.runes.toList();
  final br = b.runes.toList();
  if ((ar.length - br.length).abs() > cap) return cap + 1;
  var prev = List<int>.generate(br.length + 1, (i) => i);
  for (var i = 1; i <= ar.length; i++) {
    final cur = [i, ...List<int>.filled(br.length, 0)];
    var rowMin = i;
    for (var j = 1; j <= br.length; j++) {
      final cost = ar[i - 1] == br[j - 1] ? 0 : 1;
      var v = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      if (ins < v) v = ins;
      final sub = prev[j - 1] + cost;
      if (sub < v) v = sub;
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > cap) return cap + 1;
    prev = cur;
  }
  return prev[br.length];
}

/// Typo rescue: indexed words within [maxDistance] of a missed query
/// token, nearest first. Powers "did you mean?" on empty results.
List<String> didYouMean(
  String queryToken,
  Set<String> vocabulary, {
  int maxDistance = 2,
  int limit = 3,
}) {
  final q = queryToken.toLowerCase();
  if (q.length < 3 || vocabulary.contains(q)) return [];
  final cands = <String, int>{};
  for (final w in vocabulary) {
    if ((w.length - q.length).abs() > maxDistance) continue;
    final d = editDistance(q, w, cap: maxDistance);
    if (d <= maxDistance) cands[w] = d;
  }
  final sorted = cands.entries.toList()
    ..sort((a, b) {
      final c = a.value.compareTo(b.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return [for (final e in sorted.take(limit)) e.key];
}
