import 'dart:typed_data';

import 'index_database.dart';
import 'pro_gate.dart';
import 'query_engine.dart';
import 'stub_embed.dart';

/// Text-to-vector behind an interface (Phase 3, task 1).
/// Device build plugs in the MobileCLIP text tower
/// (clip_text_s2.tflite via tflite_flutter); until then the stub keeps the
/// full query path — token lookup, vector scan, date filter, fusion —
/// real and measurable.
abstract class TextEmbedder {
  /// 0-255 INT8-style vector matching the stored embedding dimension.
  Future<List<int>> embed(String query);
  int get dimension;
}

class StubTextEmbedder implements TextEmbedder {
  const StubTextEmbedder();

  @override
  int get dimension => 32;

  @override
  Future<List<int>> embed(String query) async => stubEmbedText(query, dimension);
}

/// Full query path (Phase 3, task 1; Phase 4 frame scan):
/// embed query -> vector top-K + token lookup + frame top-K + date filter
/// -> fuse + rank. Reads committed rows only, so search stays live while
/// indexing runs.
///
/// visualFloor (0-100): visual-/frame-only results below it are dropped
/// (Phase 4 open decision resolved): a gibberish query must yield a clean
/// empty state instead of random lookalikes. Text-backed hits always pass.
/// Default 50 = "must reach the mid band on its own evidence".
class SearchService {
  /// Lone-visual admission threshold for real CLIP vectors (512-d):
  /// genuine matches land ~0.25+, random pairs ~0.05-0.15. Initial device
  /// calibration — the Phase 5 settings dialog prints vecTop per query, so
  /// this tunes from one paste. Stub-era (32-d) keeps the 0.9 gate.
  static const clipVisualMinSim = 0.25;
  static const stubVisualMinSim = 0.9;

  final IndexDatabase db;
  final TextEmbedder embedder;
  final double visualFloor;

  /// Tier gate (Phase 5, task 6). AppIndex owns the instance; tests and
  /// diagnostics may inject their own tier.
  final ProGate gate;
  SearchService({
    required this.db,
    required this.embedder,
    this.visualFloor = 50,
    ProGate? gate,
  }) : gate = gate ?? ProGate();

  /// Which lone-visual gate applies: CLIP space separates meaning from
  /// noise, stub space doesn't.
  double get visualMinSim =>
      embedder.dimension == 512 ? clipVisualMinSim : stubVisualMinSim;

  Future<List<RankedResult>> search(
    String rawQuery, {
    int limit = 50,
    DateTime? now,
    void Function(String line)? trace,
  }) async {
    final outcome = await searchDetailed(
      rawQuery,
      limit: limit,
      now: now,
      trace: trace,
    );
    return outcome.results;
  }

  /// Query path with tier resolution (Phase 5, task 4+6): fuzzy-temporal
  /// queries run unconstrained on Free and report the preview feature so
  /// the UI can show the inline preview + paywall.
  Future<
      ({
        List<RankedResult> results,
        DateFilter filter,
        ProFeature? preview,
      })> searchDetailed(
    String rawQuery, {
    int limit = 50,
    DateTime? now,
    void Function(String line)? trace,
  }) async {
    final prepared = prepareQuery(rawQuery, now: now);
    final resolved = resolveFilter(
      parsed: prepared.filter,
      isPro: gate.isPro,
    );
    final results = await _run(
      prepared.tokens,
      filter: resolved.filter,
      limit: limit,
      trace: trace,
    );
    return (
      results: results,
      filter: resolved.filter,
      preview: resolved.preview,
    );
  }

  /// Query with an explicit date-chip selection (task 2 filter row).
  Future<List<RankedResult>> searchWithRange(
    String rawQuery, {
    int? fromMillis,
    int? toMillis,
    int limit = 50,
    DateTime? now,
    void Function(String line)? trace,
  }) async {
    final prepared = prepareQuery(rawQuery, now: now);
    final filter = (fromMillis != null || toMillis != null)
        ? DateFilter(fromMillis: fromMillis, toMillis: toMillis)
        : prepared.filter;
    return _run(prepared.tokens, filter: filter, limit: limit, trace: trace);
  }

  /// Find visually similar items (Phase 5, task 5; PRD §3).
  /// Pro-gated; Free callers get an empty result and the preview flag.
  Future<
      ({
        List<RankedResult> results,
        ProFeature? preview,
      })> findSimilar(
    List<int> referenceVector, {
    int limit = 50,
  }) async {
    if (!gate.isPro) {
      return (results: <RankedResult>[], preview: ProFeature.visualSimilarity);
    }
    final vectorHits = await db.vectorScan(
      Uint8List.fromList(referenceVector),
      limit: limit,
    );
    // Visual-only fusion (no text hits).
    final results = fuseAndRank(
      tokenHits: const {},
      vectorHits: vectorHits,
      files: await db.filesByIds(vectorHits.keys.toSet()),
      limit: limit,
      // "Find similar" bypasses the visualFloor since the user
      // explicitly picked a reference item.
      visualFloor: 0,
      visualMinSim: visualMinSim,
    );
    return (results: results, preview: null);
  }

  /// Find visually similar items by ID (Phase 5, task 5).
  /// CLIP era (512-d): vector KNN — genuine lookalikes.
  /// Stub era (32-d hash vectors carry no meaning): text similarity over
  /// shared indexed words instead — photos sharing labels/OCR words ARE
  /// visibly about the same things. Returning only the reference itself
  /// (what the vector path degrades to) is never useful, so the reference
  /// leads but real neighbors follow.
  Future<
      ({
        List<RankedResult> results,
        ProFeature? preview,
      })> findSimilarById(int fileId) async {
    if (embedder.dimension == 512) {
      final vec = await db.vectorForFile(fileId);
      if (vec == null) return (results: <RankedResult>[], preview: null);
      return findSimilar(vec);
    }
    if (!gate.isPro) {
      return (results: <RankedResult>[], preview: ProFeature.visualSimilarity);
    }
    final text = await db.ocrTextForFile(fileId);
    final tokens = IndexDatabase.tokenizeForIndex(text);
    if (tokens.isEmpty) return (results: <RankedResult>[], preview: null);
    final hits = await db.sharedTokenMatches('ocr', tokens, limit: 50);
    if (hits.isEmpty) return (results: <RankedResult>[], preview: null);
    final files = await db.filesByIds(hits.keys.toSet());
    final results = fuseAndRank(
      tokenHits: hits,
      vectorHits: const {},
      files: files,
      limit: 50,
      visualFloor: 0,
    );
    return (results: results, preview: null);
  }

  /// Last-resort recall: when fusion yields nothing, rows whose OCR text
  /// contains a query token as a substring. Scores stay modest (55 + 5 per
  /// extra token hit, capped at 70) — weak evidence must never outrank real
  /// matches, just rescue dead ends. Date filters apply here too.
  Future<List<RankedResult>> _substringFallback(
    String tokens, {
    required DateFilter filter,
    required int limit,
    void Function(String line)? trace,
  }) async {
    final tokenList = IndexDatabase.tokenizeForIndex(tokens);
    if (tokenList.isEmpty) return [];
    var subs = await db.ocrSubstringIds(tokenList);
    if (subs.isEmpty) return [];
    if (filter.isActive) {
      final inRange = (await db.filesInDateRange(
        filter.fromMillis,
        filter.toMillis,
      ))
          .toSet();
      subs.removeWhere((id, _) => !inRange.contains(id));
      if (subs.isEmpty) return [];
    }
    final files = await db.filesByIds(subs.keys.toSet());
    final out = <RankedResult>[];
    for (final e in subs.entries) {
      final file = files[e.key];
      if (file == null) continue;
      out.add(
        RankedResult(
          fileId: e.key,
          uri: file['uri'] as String,
          isVideo: (file['type'] as String) == 'video',
          mtime: (file['mtime'] as int?) ?? 0,
          score: (55 + 5 * (e.value - 1)).clamp(0, 70),
          matchedVia: const {'text'},
        ),
      );
    }
    out.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      if (a.isVideo != b.isVideo) return a.isVideo ? -1 : 1;
      return a.fileId.compareTo(b.fileId);
    });
    trace?.call('substring fallback: n=${out.length}');
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  Future<List<RankedResult>> _run(
    String tokens, {
    required DateFilter filter,
    required int limit,
    void Function(String line)? trace,
  }) async {
    // Keyword-era recall: synonyms expand the TOKEN search only. The
    // vector embedder keeps the raw tokens (expansion would scramble
    // embedding geometry, stub or CLIP alike).
    final expanded = expandQuery(tokens);
    final tokenRows = await db.tokenSearch('ocr', expanded, limit: limit);
    // Phase 5: also search spoken words (transcript tokens). The
    // transcript corpus is videos-only (tiny), so a wide limit is free.
    final speechRows =
        await db.tokenSearch('transcript', expanded, limit: 500);

    final tokenHits = <int, int>{};
    for (final r in tokenRows) {
      final id = r['ref_id'] as int;
      tokenHits[id] = (tokenHits[id] ?? 0) + (r['hits'] as int);
    }
    final ocrIds = tokenHits.keys.toSet();
    final crowded = <int>[];
    for (final r in speechRows) {
      final id = r['ref_id'] as int;
      tokenHits[id] = (tokenHits[id] ?? 0) + (r['hits'] as int);
      if (!ocrIds.contains(id)) crowded.add(id);
    }
    // Rows the transcript matched but the LIMIT-50 ocr window crowded out
    // lose their caption evidence (e.g. a video whose spoken words match
    // but whose caption didn't make the window). Fetch their ocr hits
    // directly so spoken + captioned evidence combine instead of compete.
    if (crowded.isNotEmpty) {
      final extra = await db.tokenHitsForIds('ocr', expanded, crowded.toSet());
      for (final e in extra.entries) {
        tokenHits[e.key] = (tokenHits[e.key] ?? 0) + e.value;
      }
    }

    var vectorHits = <int, double>{};
    var frameHits = <int, ({double sim, double t})>{};
    if (tokens.trim().isNotEmpty) {
      final qvec = await embedder.embed(tokens);
      vectorHits = await db.vectorScan(
        Uint8List.fromList(qvec),
        limit: limit,
      );
      // Phase 4: sampled-video frames run through the same query vector.
      frameHits = await db.frameVectorScan(
        Uint8List.fromList(qvec),
        limit: limit,
      );
    }
    trace?.call(
      'signals: text=${tokenHits.length} vec=${vectorHits.length} '
      'frame=${frameHits.length} floor=$visualFloor',
    );

    final union = {
      ...tokenHits.keys,
      ...vectorHits.keys,
      ...frameHits.keys,
    };
    var files = await db.filesByIds(union);
    trace?.call(
      'filesByIds: ${files.length}/${union.length} '
      'frame-ids present: '
      '${frameHits.keys.where(files.containsKey).length}/${frameHits.length}',
    );

    if (filter.isActive) {
      final inRange = (await db.filesInDateRange(
        filter.fromMillis,
        filter.toMillis,
      ))
          .toSet();
      files = {
        for (final e in files.entries)
          if (inRange.contains(e.key)) e.key: e.value,
      };
      tokenHits.removeWhere((id, _) => !inRange.contains(id));
      vectorHits.removeWhere((id, _) => !inRange.contains(id));
      frameHits.removeWhere((id, _) => !inRange.contains(id));
      trace?.call(
        'after date filter: frame=${frameHits.length} '
        '(filter active: ${filter.isActive})',
      );
    }

    var fused = fuseAndRank(
      tokenHits: tokenHits,
      vectorHits: vectorHits,
      frameHits: frameHits,
      files: files,
      limit: limit,
      visualFloor: visualFloor,
      visualMinSim: visualMinSim,
    );
    if (fused.isEmpty) {
      fused = await _substringFallback(
        expanded,
        filter: filter,
        limit: limit,
        trace: trace,
      );
    }
    if (trace != null && frameHits.isNotEmpty) {
      final frameIds = frameHits.keys.toSet();
      final kept = fused
          .where((r) => frameIds.contains(r.fileId))
          .map(
            (r) => 'id${r.fileId}:${r.score}%@${r.bestFrameSecs ?? '-'}s',
          )
          .join(' ');
      final at100 = fused.where((r) => r.score == 100).length;
      final cutoff = fused.isEmpty ? -1 : fused.last.score;
      // Discriminator for stale-build vs data flood: text-only rows cap at
      // 90, so at100 with modes={text: N} means the old formula is running;
      // at100 with dual/visual modes means vec sims round to 100.
      final modes = <String, int>{};
      for (final r in fused) {
        final k = r.matchedVia.length == 2
            ? 'dual'
            : r.matchedVia.contains('text')
                ? 'text'
                : 'visual';
        modes[k] = (modes[k] ?? 0) + 1;
      }
      final maxTok =
          tokenHits.values.fold<int>(0, (a, b) => a > b ? a : b);
      final vecTop = vectorHits.values
          .take(3)
          .map((v) => v.toStringAsFixed(2))
          .join(',');
      trace(
        'fusion: n=${fused.length} at100=$at100 cutoff=$cutoff '
        'modes=$modes maxTok=$maxTok vecTop=[$vecTop] '
        'frame-ids kept=[${kept.isEmpty ? 'none' : kept}]',
      );
    }
    return fused;
  }
}
