import 'index_database.dart';
import 'query_engine.dart';
import 'search_service.dart';
import 'video_indexer.dart';

/// DEBUG ONLY — demo library seeder (Phase 3 device walkthrough).
///
/// Writes hand-written sample rows through the REAL pipeline
/// ([IndexDatabase.insertIndexed]: files + embeddings + OCR + tokens), so
/// search, filters, scores and the preview modal are exercisable on device
/// before the real MediaStore source lands. Dates are spread across today,
/// yesterday, last week and older, so the date filter row does something.
/// Re-running replaces the demo rows instead of duplicating them.
class DemoSeed {
  static const scopePrefix = 'demo://sample-library';

  static List<({String uri, bool isVideo, String ocr, int daysAgo})> get rows =>
      [
        (uri: 'receipt_home_depot.jpg', isVideo: false, ocr: 'HOME DEPOT receipt total 84 dollars paint supplies', daysAgo: 0),
        (uri: 'receipt_grocery.jpg', isVideo: false, ocr: 'grocery receipt whole foods thirty two fifty fresh produce', daysAgo: 1),
        (uri: 'passport_scan.jpg', isVideo: false, ocr: 'passport scan doe travel document identity', daysAgo: 6),
        (uri: 'sunset_pier.jpg', isVideo: false, ocr: 'sunset over the pier ocean sky evening summer', daysAgo: 2),
        (uri: 'sunset_mountains.jpg', isVideo: false, ocr: 'mountain sunset hike sky evening view', daysAgo: 9),
        (uri: 'dog_park.jpg', isVideo: false, ocr: 'dog playing on green grass park ball pet', daysAgo: 3),
        (uri: 'birthday_dinner.mp4', isVideo: true, ocr: 'happy birthday dinner celebration singing cake friends', daysAgo: 1),
        (uri: 'beach_vlog.mp4', isVideo: true, ocr: 'beach vlog sunset ocean waves summer vacation', daysAgo: 5),
        (uri: 'standup_meeting.mp4', isVideo: true, ocr: 'team standup meeting deploy friday beta release work', daysAgo: 0),
        (uri: 'invoice_freelance.jpg', isVideo: false, ocr: 'invoice freelance design work payment due receipt', daysAgo: 12),
        (uri: 'beach_sunrise.jpg', isVideo: false, ocr: 'beach sunrise morning ocean sand summer', daysAgo: 4),
        (uri: 'birthday_cake.jpg', isVideo: false, ocr: 'birthday cake candles happy celebration party', daysAgo: 8),
      ];

  /// Vocabulary pool for the scale test: broad enough that queries
  /// discriminate (not every doc matches everything).
  static const scaleWords = [
    'receipt', 'sunset', 'dog', 'birthday', 'beach', 'invoice', 'mountain',
    'dinner', 'scan', 'park', 'ocean', 'cake', 'meeting', 'hike', 'passport',
    'groceries', 'concert', 'wedding', 'graduation', 'picnic', 'museum',
    'street', 'market', 'coffee', 'garden', 'lake', 'forest', 'city',
    'bridge', 'tower', 'festival', 'parade', 'match', 'stadium', 'camp',
    'desert', 'island', 'harbor', 'plaza', 'theater',
  ];

  /// Scale-test queries: mix of common, rare and multi-token.
  static const scaleQueries = [
    'receipt',
    'sunset',
    'birthday cake',
    'beach ocean summer',
    'passport scan document',
    'zxqvkw', // guaranteed no-match: exercises the empty path
  ];

  /// Seed (or reseed) the demo library. Returns rows written.
  static Future<int> seed(
    IndexDatabase db, {
    TextEmbedder? embedder,
  }) async {
    final ext = embedder ?? const StubTextEmbedder();
    // Idempotent: clear previous demo rows first.
    await db.deleteByScopePrefix(scopePrefix);
    final now = DateTime.now();
    var n = 0;
    for (final row in rows) {
      final mtime =
          now.subtract(Duration(days: row.daysAgo)).millisecondsSinceEpoch;
      final uri = '$scopePrefix/${row.uri}';
      // Deterministic content-derived vector (stub stands in for CLIP).
      final vector = await ext.embed(row.ocr);
      final size = 2048 + uri.length;
      await db.insertIndexed(
        uri: uri,
        isVideo: row.isVideo,
        mtime: mtime,
        size: size,
        width: 4000,
        height: 3000,
        // Same fingerprint format the crawler uses (uri|mtime|size).
        hash: '$uri|$mtime|$size',
        vector: vector,
        modelVer: ext is StubTextEmbedder ? 'stub-v0' : 'device-v1',
        ocrText: row.ocr,
      );
      n++;
    }
    return n;
  }

  static const scaleScopePrefix = 'scale://synthetic-20k';

  /// Phase 4 — demo VIDEO rows + sampled frames (debug only).
  ///
  /// Writes real `files`/`embeddings`/`ocr`/`tokens` rows (isVideo=true,
  /// duration set) through [IndexDatabase.insertIndexed], then runs the
  /// [VideoIndexer] sampling math (1 frame / 2.5s, first 5 min cap) and
  /// stores one row per sampled frame in `frames`.
  ///
  /// Frame vectors are scene tags embedded with the same stub embedder the
  /// query path uses: an exact single-token query ("ocean") re-embeds to a
  /// byte-identical vector, so frame fusion is demonstrable before real
  /// CLIP image-tower vectors land (device step: swap in clip_joint_s2).
  static const videoScopePrefix = 'demo://sample-videos';

  static List<
      ({
        String uri,
        String ocr,
        double durationSecs,
        int daysAgo,
        List<String> scenes,
      })> get videoRows => [
        (
          uri: 'birthday_party.mp4',
          ocr: 'birthday party candles cake singing celebration',
          durationSecs: 74,
          daysAgo: 2,
          scenes: ['birthday', 'cake', 'candles', 'singing'],
        ),
        (
          uri: 'ocean_waves.mp4',
          ocr: 'ocean waves crashing on rocks beach drone footage',
          durationSecs: 145,
          daysAgo: 7,
          scenes: ['ocean', 'waves', 'beach', 'sunset'],
        ),
        (
          uri: 'office_standup.mp4',
          ocr: 'office standup meeting sprint board whiteboard',
          durationSecs: 62,
          daysAgo: 0,
          scenes: ['meeting', 'whiteboard', 'office', 'sprint'],
        ),
        (
          // 305s > 300s Free cap — proves the first-5-min sampling budget.
          uri: 'hike_trail.mp4',
          ocr: 'mountain hike trail forest river view',
          durationSecs: 305,
          daysAgo: 14,
          scenes: ['hike', 'forest', 'river', 'mountain'],
        ),
      ];

  /// Seed (or reseed) demo videos + frame rows. Returns frames written.
  static Future<int> seedDemoVideos(
    IndexDatabase db, {
    TextEmbedder? embedder,
  }) async {
    final ext = embedder ?? const StubTextEmbedder();
    // Independent scope: coexists with the photo demo, cleared separately.
    await db.deleteByScopePrefix(videoScopePrefix);
    final now = DateTime.now();
    var frames = 0;
    for (final row in videoRows) {
      final mtime =
          now.subtract(Duration(days: row.daysAgo)).millisecondsSinceEpoch;
      final uri = '$videoScopePrefix/${row.uri}';
      final size = 1024 * 1024 + uri.length;
      final fileId = await db.insertIndexed(
        uri: uri,
        isVideo: true,
        mtime: mtime,
        size: size,
        width: 1920,
        height: 1080,
        duration: row.durationSecs,
        hash: '$uri|$mtime|$size',
        vector: await ext.embed(row.ocr),
        modelVer: ext is StubTextEmbedder ? 'stub-v0' : 'device-v1',
        ocrText: row.ocr,
      );
      // Same sampling the device VideoIndexer uses (2.5s / 300s cap).
      final times = VideoIndexer.sampleTimes(row.durationSecs);
      final vectors = <double, List<int>>{};
      for (var i = 0; i < times.length; i++) {
        final scene = row.scenes[i % row.scenes.length];
        vectors[times[i]] = await ext.embed(scene);
      }
      await db.insertFrames(fileId, vectors);
      frames += vectors.length;
    }
    return frames;
  }

  /// Remove demo, video-demo AND scale rows (keeps real rows, if any).
  static Future<void> clearSynthetic(IndexDatabase db) async {
    await db.deleteByScopePrefix(scopePrefix);
    await db.deleteByScopePrefix(videoScopePrefix);
    await db.deleteByScopePrefix(scaleScopePrefix);
  }

  /// Write [count] synthetic rows for the 20k p95 scale test.
  /// Reports progress every 500 rows via [onProgress]. Idempotent: clears
  /// previous scale rows first. Slow by design on first run (real commits);
  /// expect a few minutes at 20k on midrange hardware.
  static Future<int> seedScale(
    IndexDatabase db, {
    int count = 20000,
    TextEmbedder? embedder,
    void Function(int done, int total)? onProgress,
  }) async {
    final ext = embedder ?? const StubTextEmbedder();
    await db.deleteByScopePrefix(scaleScopePrefix);
    final now = DateTime.now();
    var seed = 12345;
    // Deterministic PRNG (no dart:math import needed elsewhere).
    int next(int max) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % max;
    }

    for (var i = 0; i < count; i++) {
      final words = List<String>.generate(
        4 + next(3),
        (_) => scaleWords[next(scaleWords.length)],
      ).join(' ');
      final ocr = '$words doc$i';
      final daysAgo = next(365);
      final mtime = now
          .subtract(Duration(days: daysAgo))
          .millisecondsSinceEpoch;
      final uri =
          '$scaleScopePrefix/img_${i.toString().padLeft(5, '0')}.jpg';
      final size = 2048 + (i % 4096);
      await db.insertIndexed(
        uri: uri,
        isVideo: false,
        mtime: mtime,
        size: size,
        width: 4000,
        height: 3000,
        hash: '$uri|$mtime|$size',
        vector: await ext.embed(ocr),
        modelVer: 'scale-stub-v0',
        ocrText: ocr,
      );
      if ((i + 1) % 500 == 0) onProgress?.call(i + 1, count);
    }
    onProgress?.call(count, count);
    return count;
  }

  /// Time each [scaleQueries] query through the real [SearchService] and
  /// report per-query ms plus p95. Measures everything except real
  /// embedding math (stub vectors) — the DB-level p95 at scale.
  static Future<ScaleResult> runScaleQueries(SearchService search) async {
    final timings = <String, int>{};
    final counts = <String, int>{};
    for (final q in scaleQueries) {
      final sw = Stopwatch()..start();
      final List<RankedResult> out = await search.search(q);
      sw.stop();
      timings[q] = sw.elapsedMilliseconds;
      counts[q] = out.length;
    }
    final sorted = timings.values.toList()..sort();
    final p95 = sorted[((sorted.length * 0.95).ceil() - 1)
        .clamp(0, sorted.length - 1)];
    return ScaleResult(timings: timings, counts: counts, p95Ms: p95);
  }
}

/// Device p95 report. Send the whole string back — it closes the scale test.
class ScaleResult {
  final Map<String, int> timings;
  final Map<String, int> counts;
  final int p95Ms;
  const ScaleResult({
    required this.timings,
    required this.counts,
    required this.p95Ms,
  });

  @override
  String toString() {
    final lines = [
      for (final q in timings.keys) '"$q": ${timings[q]}ms (${counts[q]} hits)',
    ];
    lines.add('p95: ${p95Ms}ms (budget <500ms)');
    lines.add(p95Ms < 500 ? 'Verdict: PASS' : 'Verdict: OVER BUDGET');
    return lines.join('\n');
  }
}
