import 'dart:io';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// Air-gapped index DB (Phase 2, task 2).
/// Schema mirrors tools/schema_v1.sql — keep them in sync
/// (tools/phase2_check.py enforces column parity).
class IndexDatabase {
  final Database db;
  IndexDatabase(this.db);

  static const _schema = '''
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uri TEXT NOT NULL UNIQUE,
  type TEXT NOT NULL CHECK (type IN ('photo','video')),
  mtime INTEGER NOT NULL,
  size INTEGER,
  width INTEGER,
  height INTEGER,
  duration REAL,
  hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS embeddings (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  vec_int8 BLOB NOT NULL,
  model_ver TEXT NOT NULL,
  PRIMARY KEY (file_id, model_ver)
);
CREATE TABLE IF NOT EXISTS ocr (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE PRIMARY KEY,
  text TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS frames (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  t REAL NOT NULL,
  vec_int8 BLOB NOT NULL,
  PRIMARY KEY (file_id, t)
);
CREATE TABLE IF NOT EXISTS transcripts (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  t_start REAL NOT NULL,
  t_end REAL NOT NULL,
  text TEXT NOT NULL,
  PRIMARY KEY (file_id, t_start)
);
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  event TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
-- Token index (replaces FTS5 — system SQLite on some OEM Android builds
-- lacks the FTS5 module; a plain table works everywhere, zero native deps).
-- Tokenizer contract: see tokenizeForIndex; mirrored in Python harnesses.
CREATE TABLE IF NOT EXISTS tokens (
  kind TEXT NOT NULL,
  token TEXT NOT NULL,
  ref_id INTEGER NOT NULL,
  PRIMARY KEY (kind, token, ref_id)
);
CREATE INDEX IF NOT EXISTS idx_tokens_token ON tokens(token);
''';

  /// Tokenizer for the token index. Contract (mirrored in tools/*.py):
  /// lowercase, split on [^a-z0-9]+, drop tokens < 2 chars, light English
  /// stemming (plurals + verb forms collapse: receipts/receipt,
  /// following/follow, sunsets/sunset), dedupe.
  /// Stemming applies identically at index and query time, so old rows
  /// must be re-indexed on tokenizer change (extractor modelVersion bump).
  /// Pure — unit-tested in test/indexer_test.dart.
  static List<String> tokenizeForIndex(String text) {
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.length >= 2)
        .map(stemToken)
        .toSet()
        .toList();
  }

  /// Light English stemmer: strips -ing/-ed/-ies/-es/-s with guards against
  /// over-stemming shorts, plus double-consonant collapse (running -> run).
  /// Conservative by design: wrong stems only ever merge related words;
  /// identical application on both sides keeps index and query consistent.
  /// Pure — unit-tested.
  static String stemToken(String t) {
    String stem = t;
    if (stem.length > 6 && stem.endsWith('ing')) {
      stem = stem.substring(0, stem.length - 3);
    } else if (stem.length > 5 && stem.endsWith('ed')) {
      stem = stem.substring(0, stem.length - 2);
    } else if (stem.length > 4 && stem.endsWith('ies')) {
      stem = '${stem.substring(0, stem.length - 3)}y';
    } else if (stem.length > 4 &&
        (stem.endsWith('sses') ||
            stem.endsWith('xes') ||
            stem.endsWith('zes') ||
            stem.endsWith('ches') ||
            stem.endsWith('shes') ||
            stem.endsWith('ses'))) {
      // boxes -> box, dresses/buses -> dress/bus, beaches -> beach.
      stem = stem.substring(0, stem.length - 2);
    } else if (stem.length > 4 &&
        stem.endsWith('s') &&
        !stem.endsWith('ss') &&
        !stem.endsWith('us')) {
      // receipts -> receipt, sunsets -> sunset, shoes -> shoe.
      stem = stem.substring(0, stem.length - 1);
    }
    // running -> runn -> run; stopped -> stopp -> stop.
    if (stem.length >= 4 &&
        stem[stem.length - 1] == stem[stem.length - 2]) {
      final c = stem[stem.length - 1];
      if ('bdfgklmnprst'.contains(c)) {
        stem = stem.substring(0, stem.length - 1);
      }
    }
    return stem.length >= 2 ? stem : t;
  }

  /// Ranked token lookup for Phase 3 search: most query-token hits first.
  /// Exact matches plus prefix matches for tokens >= 4 chars (anim* finds
  /// anime). COUNT(DISTINCT token): a row matching a token exactly and by
  /// prefix still counts one hit. Tokens are [a-z0-9]+ by construction, so
  /// the LIKE patterns need no escaping.
  Future<List<Map<String, Object?>>> tokenSearch(
    String kind,
    String query, {
    int limit = 50,
  }) async {
    final tokens = tokenizeForIndex(query);
    if (tokens.isEmpty) return [];
    final (where, args) = _tokenWhere(tokens);
    return db.rawQuery(
      'SELECT ref_id, COUNT(DISTINCT token) AS hits FROM tokens '
      'WHERE kind = ? AND ($where) '
      'GROUP BY ref_id ORDER BY hits DESC LIMIT ?',
      [kind, ...args, limit],
    );
  }

  /// Shared exact+prefix predicate for [tokenSearch]/[tokenHitsForIds].
  (String, List<Object?>) _tokenWhere(List<String> tokens) {
    final conds = <String>[
      'token IN (${List.filled(tokens.length, '?').join(',')})',
    ];
    final args = <Object?>[...tokens];
    for (final t in tokens) {
      if (t.length >= 4) {
        conds.add('token LIKE ?');
        args.add('$t%');
      }
    }
    return (conds.join(' OR '), args);
  }

  /// Targeted token-hit counts for explicit ids (Phase 5 transcript merge).
  /// Same ranking math as [tokenSearch] without the top-K truncation, so
  /// rows matched by one signal kind keep their evidence from another.
  Future<Map<int, int>> tokenHitsForIds(
    String kind,
    String query,
    Set<int> ids,
  ) async {
    final tokens = tokenizeForIndex(query);
    if (tokens.isEmpty || ids.isEmpty) return {};
    final (where, args) = _tokenWhere(tokens);
    final iPlace = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT ref_id, COUNT(DISTINCT token) AS hits FROM tokens '
      'WHERE kind = ? AND ($where) AND ref_id IN ($iPlace) '
      'GROUP BY ref_id',
      [kind, ...args, ...ids],
    );
    return {for (final r in rows) (r['ref_id'] as int): (r['hits'] as int)};
  }

  /// Last-resort recall when no token matched at all (missed stems, OCR
  /// compounds): file ids whose OCR text contains a query token as a
  /// substring, mapped to per-row hit counts. Callers cap the resulting
  /// scores — this is weak evidence, better than zero but never 90.
  Future<Map<int, int>> ocrSubstringIds(
    List<String> tokens, {
    int limit = 200,
  }) async {
    final use = tokens.where((t) => t.length >= 3).take(6).toList();
    if (use.isEmpty) return {};
    final rows = await db.query(
      'ocr',
      columns: const ['file_id'],
      where: use.map((_) => 'text LIKE ?').join(' OR '),
      whereArgs: [for (final t in use) '%$t%'],
      limit: limit,
    );
    final out = <int, int>{};
    for (final r in rows) {
      final id = r['file_id'] as int;
      out[id] = (out[id] ?? 0) + 1;
    }
    return out;
  }

  /// Open (or create) the sandbox DB. Never outside the app sandbox.
  static Future<IndexDatabase> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      // Foreign keys are OFF by default in SQLite/sqflite: without this,
      // ON DELETE CASCADE never fires and revoke would orphan index rows.
      onConfigure: (db) async =>
          db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        // Strip -- comments BEFORE splitting: a ';' inside a comment
        // (e.g. "see X; mirrored in Y") would otherwise split mid-comment
        // and execute a comment fragment as SQL — observed on device as
        // DatabaseException "not an error (code 0 SQLITE_OK)".
        final code = _schema
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('--'))
            .join('\n');
        for (final stmt in code.split(';')) {
          final sql = stmt.trim();
          if (sql.isNotEmpty) await db.execute(sql);
        }
      },
    );
    return IndexDatabase(db);
  }

  Future<Map<String, Object?>?> fileByUri(String uri) async {
    final rows = await db.query(
      'files',
      where: 'uri = ?',
      whereArgs: [uri],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Insert one fully-processed file + its index rows in a single batch
  /// commit (Phase 2, task 2). Returns the file id.
  Future<int> insertIndexed({
    required String uri,
    required bool isVideo,
    required int mtime,
    required int size,
    int? width,
    int? height,
    double? duration,
    required String hash,
    required List<int> vector,
    required String modelVer,
    String ocrText = '',
  }) async {
    final batch = db.batch();
    batch.insert('files', {
      'uri': uri,
      'type': isVideo ? 'video' : 'photo',
      'mtime': mtime,
      'size': size,
      'width': width,
      'height': height,
      'duration': duration,
      'hash': hash,
    });
    await batch.commit(noResult: true);
    final row = await fileByUri(uri);
    final id = row!['id'] as int;
    final batch2 = db.batch();
    batch2.insert('embeddings', {
      'file_id': id,
      'vec_int8': vector,
      'model_ver': modelVer,
    });
    if (ocrText.isNotEmpty) {
      batch2.insert('ocr', {'file_id': id, 'text': ocrText});
      for (final token in tokenizeForIndex(ocrText)) {
        batch2.insert('tokens', {
          'kind': 'ocr',
          'token': token,
          'ref_id': id,
        });
      }
    }
    await batch2.commit(noResult: true);
    return id;
  }

  /// Delete every indexed row whose URI belongs to a revoked scope.
  /// Embeddings/OCR/frames/transcripts follow via ON DELETE CASCADE;
  /// tokens are cleaned explicitly (their ref_id carries no FK by design,
  /// so Phase 3 transcript/frame token kinds stay flexible).
  Future<int> deleteByScopePrefix(String scopeUri) async {
    final ids = await db.query(
      'files',
      columns: ['id'],
      where: 'uri = ? OR uri LIKE ?',
      whereArgs: [scopeUri, '$scopeUri/%'],
    );
    await _deleteTokensFor(ids);
    return db.delete(
      'files',
      where: 'uri = ? OR uri LIKE ?',
      whereArgs: [scopeUri, '$scopeUri/%'],
    );
  }

  /// Delete rows for files that vanished from the source (cleanup pass).
  Future<int> deleteMissing(List<String> seenUris) async {
    if (seenUris.isEmpty) return 0;
    final placeholders = List.filled(seenUris.length, '?').join(',');
    final ids = await db.query(
      'files',
      columns: ['id'],
      where: 'uri NOT IN ($placeholders)',
      whereArgs: seenUris,
    );
    await _deleteTokensFor(ids);
    return db.delete(
      'files',
      where: 'uri NOT IN ($placeholders)',
      whereArgs: seenUris,
    );
  }

  Future<void> _deleteTokensFor(List<Map<String, Object?>> ids) async {
    for (final row in ids) {
      await db.delete(
        'tokens',
        where: 'ref_id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<int> fileCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM files');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Debug: how many sampled-frame rows exist (Phase 4 device diagnostic).
  Future<int> countFrames() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM frames');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Fetch file rows for a set of ids (fusion step of the query path).
  Future<Map<int, Map<String, Object?>>> filesByIds(Set<int> ids) async {
    if (ids.isEmpty) return {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'files',
      where: 'id IN ($placeholders)',
      whereArgs: ids.toList(),
    );
    return {for (final r in rows) (r['id'] as int): r};
  }

  /// Cosine similarity over INT8-style (0-255, zero-point 128) vectors.
  /// Returns null when either side is degenerate. Pure — unit-tested.
  static double? cosineInt8(List<int> a, List<int> b) {
    if (a.length != b.length || a.isEmpty) return null;
    var dot = 0;
    var qa = 0;
    var ba = 0;
    for (var i = 0; i < a.length; i++) {
      final x = a[i] - 128;
      final y = b[i] - 128;
      dot += x * y;
      qa += x * x;
      ba += y * y;
    }
    if (qa == 0 || ba == 0) return null;
    return dot / (sqrt(qa) * sqrt(ba));
  }

  /// Brute-force INT8 dot-product scan (Phase 3 MVP).
  /// Returns file_id -> similarity in [-1, 1]. An IVF/HNSW index replaces
  /// this when libraries exceed ~20k files (Phase 3, task 5).
  Future<Map<int, double>> vectorScan(
    List<int> queryVec, {
    int limit = 50,
  }) async {
    final rows = await db.query('embeddings');
    final scored = <int, double>{};
    for (final row in rows) {
      final sim = cosineInt8(queryVec, row['vec_int8'] as List<int>);
      if (sim != null) scored[row['file_id'] as int] = sim;
    }
    final sorted = scored.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      for (final e in sorted.take(limit)) e.key: e.value,
    };
  }

  /// Write per-frame embeddings for one video in a single batch (Phase 4).
  /// `frames` maps timestamp-seconds -> INT8 vector. Replaces any previous
  /// frames for the file, so re-indexing never duplicates timestamps.
  Future<void> insertFrames(int fileId, Map<double, List<int>> frames) async {
    await db.delete(
      'frames',
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
    if (frames.isEmpty) return;
    final batch = db.batch();
    for (final e in frames.entries) {
      batch.insert('frames', {
        'file_id': fileId,
        't': e.key,
        'vec_int8': e.value,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Best-frame scan (Phase 4, task 2): per video file, the highest frame
  /// similarity and its timestamp. Returns file_id -> (sim, bestT).
  /// Free tier plays from 0s; the timestamp is retained for Phase 5 seeking.
  Future<Map<int, ({double sim, double t})>> frameVectorScan(
    List<int> queryVec, {
    int limit = 50,
  }) async {
    final rows = await db.query('frames');
    final best = <int, ({double sim, double t})>{};
    for (final row in rows) {
      final sim = cosineInt8(queryVec, row['vec_int8'] as List<int>);
      if (sim == null) continue;
      final id = row['file_id'] as int;
      final t = (row['t'] as num).toDouble();
      final prev = best[id];
      if (prev == null || sim > prev.sim) best[id] = (sim: sim, t: t);
    }
    final sorted = best.entries.toList()
      ..sort((a, b) => b.value.sim.compareTo(a.value.sim));
    return {
      for (final e in sorted.take(limit)) e.key: e.value,
    };
  }

  /// Top-N frame matches for one file (Phase 5 filmstrip/seek UI).
  /// Same cosine as [frameVectorScan], restricted to one video.
  Future<List<({double t, double sim})>> framesForFile(
    int fileId,
    List<int> queryVec, {
    int limit = 3,
  }) async {
    final rows = await db.query(
      'frames',
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
    final scored = <({double t, double sim})>[];
    for (final row in rows) {
      final sim = cosineInt8(queryVec, row['vec_int8'] as List<int>);
      if (sim == null) continue;
      scored.add((t: (row['t'] as num).toDouble(), sim: sim));
    }
    scored.sort((a, b) => b.sim.compareTo(a.sim));
    return scored.take(limit).toList();
  }

  /// EXIF/mtime range lookup for date filters (Phase 3, task 2).
  Future<List<int>> filesInDateRange(int? from, int? to) async {
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('mtime >= ?');
      args.add(from);
    }
    if (to != null) {
      where.add('mtime <= ?');
      args.add(to);
    }
    if (where.isEmpty) return [];
    final rows = await db.query(
      'files',
      columns: ['id'],
      where: where.join(' AND '),
      whereArgs: args,
    );
    return [for (final r in rows) r['id'] as int];
  }

  /// Fetch the INT8 vector for a file (Phase 5, task 5).
  Future<List<int>?> vectorForFile(int fileId) async {
    final rows = await db.query(
      'embeddings',
      columns: ['vec_int8'],
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
    if (rows.isEmpty) return null;
    return rows.first['vec_int8'] as List<int>;
  }

  /// Top transcript segments for a file (Phase 5, task 3).
  Future<List<Map<String, Object?>>> transcriptsForFile(int fileId) async {
    return await db.query(
      'transcripts',
      where: 'file_id = ?',
      whereArgs: [fileId],
      orderBy: 't_start ASC',
    );
  }

  /// Most frequent OCR tokens — powers dynamic starter chips (Phase 3,
  /// task 4) from the indexed content distribution.
  Future<List<String>> topTokens(String kind, {int limit = 6}) async {
    final rows = await db.rawQuery(
      'SELECT token, COUNT(*) AS n FROM tokens WHERE kind = ? '
      'GROUP BY token ORDER BY n DESC LIMIT ?',
      [kind, limit],
    );
    return [for (final r in rows) r['token'] as String];
  }

  /// Prefix completion for search-as-you-type: distinct indexed tokens
  /// starting with [prefix], most frequent first. Powers the home
  /// SearchAnchor suggestions — teaches the library's vocabulary live.
  Future<List<String>> completeTokens(
    String kind,
    String prefix, {
    int limit = 6,
  }) async {
    final p = prefix.toLowerCase().trim();
    if (p.length < 2) return [];
    final rows = await db.rawQuery(
      'SELECT token, COUNT(*) AS n FROM tokens WHERE kind = ? '
      'AND token LIKE ? GROUP BY token ORDER BY n DESC LIMIT ?',
      [kind, '$p%', limit],
    );
    return [for (final r in rows) r['token'] as String];
  }

  /// Full indexed vocabulary for typo rescue (did-you-mean). Distinct
  /// tokens only; libraries stay small (hundreds of words), so callers
  /// can edit-distance them in memory. Capped to bound the scan.
  /// [minLen]/[maxLen] narrow by token length FIRST (did-you-mean only
  /// cares about ±2 of the query): without this, the cap can truncate
  /// mid-alphabet and drop the very word being fixed (device: 645 files
  /// pushed 'screenshot' past a 2000-row cap).
  Future<Set<String>> vocabulary(
    String kind, {
    int limit = 2000,
    int? minLen,
    int? maxLen,
  }) async {
    final where = <String>['kind = ?'];
    final args = <Object?>[kind];
    if (minLen != null) {
      where.add('LENGTH(token) >= ?');
      args.add(minLen);
    }
    if (maxLen != null) {
      where.add('LENGTH(token) <= ?');
      args.add(maxLen);
    }
    final rows = await db.query(
      'tokens',
      columns: ['token'],
      where: where.join(' AND '),
      whereArgs: args,
      groupBy: 'token',
      limit: limit,
    );
    return {for (final r in rows) r['token'] as String};
  }

  /// OCR text for one file (powers stub-era Find-similar: rows sharing
  /// the reference's words are genuinely similar contents).
  Future<String> ocrTextForFile(int fileId) async {
    final rows = await db.query(
      'ocr',
      columns: ['text'],
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return (rows.first['text'] as String?) ?? '';
  }

  /// Rows sharing the most tokens with [tokens] (stub-era similarity).
  /// Returns ref_id -> shared-token count, most shared first.
  Future<Map<int, int>> sharedTokenMatches(
    String kind,
    List<String> tokens, {
    int limit = 50,
  }) async {
    if (tokens.isEmpty) return {};
    final placeholders = List.filled(tokens.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT ref_id, COUNT(DISTINCT token) AS hits FROM tokens '
      'WHERE kind = ? AND token IN ($placeholders) '
      'GROUP BY ref_id ORDER BY hits DESC LIMIT ?',
      [kind, ...tokens, limit],
    );
    return {for (final r in rows) (r['ref_id'] as int): (r['hits'] as int)};
  }

  /// Local-only audit event (Phase 6, task 4): app start, telemetry
  /// dispatches, paywall/subscribe actions. The table self-heals with
  /// CREATE TABLE IF NOT EXISTS so v1 device DBs (no migration) work too.
  Future<void> logAudit(String event, [String detail = '']) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS audit_log ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'ts INTEGER NOT NULL, '
      'event TEXT NOT NULL, '
      "detail TEXT NOT NULL DEFAULT '')",
    );
    await db.insert('audit_log', {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'event': event,
      'detail': detail,
    });
  }

  Future<int> auditCount() async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS audit_log ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'ts INTEGER NOT NULL, '
      'event TEXT NOT NULL, '
      "detail TEXT NOT NULL DEFAULT '')",
    );
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM audit_log');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<List<Map<String, Object?>>> recentAudit({int limit = 20}) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS audit_log ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'ts INTEGER NOT NULL, '
      'event TEXT NOT NULL, '
      "detail TEXT NOT NULL DEFAULT '')",
    );
    return db.query('audit_log', orderBy: 'id DESC', limit: limit);
  }

  /// Sandbox index size in bytes (Phase 6 settings display).
  Future<int> indexDbBytes() async {
    try {
      return await File(db.path).length();
    } catch (_) {
      return 0;
    }
  }

  /// Real (non-synthetic) file count — Free 10k cap accounting (Phase 7).
  /// Debug scopes (demo://, scale://) never count toward the cap.
  Future<int> realFileCount() async {
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS n FROM files WHERE uri NOT LIKE 'demo://%' "
      "AND uri NOT LIKE 'scale://%'",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Wipe the whole index (Phase 6 rebuild). Cascades clear embeddings,
  /// OCR, frames, transcripts and tokens.
  Future<void> clearIndex() async {
    await db.delete('files');
  }

  Future<void> close() => db.close();
}
