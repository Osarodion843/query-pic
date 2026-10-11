import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'crawler.dart';
import 'index_database.dart';
import 'index_worker.dart';
import 'media_source.dart';
import 'scope_store.dart';

/// On-device pipeline benchmark (Phase 2, task 5).
///
/// Runs the REAL worker + REAL sqflite DB against synthetic entries, so the
/// measured ms/file covers everything except feature extraction (the stub
/// extractor stands in for CLIP/OCR until models land — real ML will be
/// slower, and that delta is measured separately when models arrive).
/// Invoke from Settings → "Run pipeline benchmark". DEBUG ONLY.
class BenchmarkResult {
  final int files;
  final int totalMs;
  final double msPerFile;
  final int dbKb;
  final double projectedMbPer10k;
  final int rows;
  const BenchmarkResult({
    required this.files,
    required this.totalMs,
    required this.msPerFile,
    required this.dbKb,
    required this.projectedMbPer10k,
    required this.rows,
  });

  @override
  String toString() =>
      '$files files in ${totalMs}ms (${msPerFile.toStringAsFixed(2)} ms/file), '
      'DB ${dbKb}KB → ~${projectedMbPer10k.toStringAsFixed(1)}MB/10k, rows=$rows';
}

Future<BenchmarkResult> runPipelineBenchmark({int count = 200}) async {
  final dir = await getApplicationDocumentsDirectory();
  final path =
      '${dir.path}/bench_${DateTime.now().millisecondsSinceEpoch}.db';
  final db = await IndexDatabase.open(path);
  // Synthetic scope keeps benchmark rows out of the user's real index.
  // Previous scopes are restored afterwards — the benchmark is traceless.
  final previousScopes = await ScopeStore.getScopedUris();
  await ScopeStore.setScopedUris(['bench://synthetic']);
  final worker = IndexWorker(
    source: SyntheticMediaSource(count: count),
    db: db,
  );
  final sw = Stopwatch()..start();
  await worker.runOnce();
  sw.stop();
  await worker.dispose();

  final rows = await db.fileCount();
  await db.close();
  final bytes = await File(path).length();
  await File(path).delete();
  await ScopeStore.setScopedUris(previousScopes);

  final kb = bytes ~/ 1024;
  return BenchmarkResult(
    files: count,
    totalMs: sw.elapsedMilliseconds,
    msPerFile: sw.elapsedMilliseconds / count,
    dbKb: kb,
    projectedMbPer10k: kb / count * 10000 / 1024,
    rows: rows,
  );
}

/// Exposed for tests: the crawler must see exactly the synthetic set.
Future<List<MediaEntry>> benchmarkQueuePreview(IndexDatabase db, int count) {
  final crawler = Crawler(
    source: SyntheticMediaSource(count: count),
    db: db,
  );
  return crawler.diff(['bench://synthetic']);
}
