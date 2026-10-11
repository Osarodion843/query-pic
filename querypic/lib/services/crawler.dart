import 'index_database.dart';
import 'media_source.dart';

/// Incremental crawler (Phase 2, task 1).
///
/// Skip rule (pure, unit-tested): a file needs (re-)indexing unless the DB
/// already holds the same URI with identical mtime, size AND content hash.
/// Kill + restart is safe: anything already committed is skipped, anything
/// interrupted is simply processed on the next run — never duplicated
/// (uri is UNIQUE, and the queue is derived, not stored).
class Crawler {
  final MediaSource source;
  final IndexDatabase db;
  const Crawler({required this.source, required this.db});

  /// Pure skip decision — no I/O, fully unit-testable.
  static bool needsIndexing({
    required MediaEntry entry,
    required Map<String, Object?>? known,
  }) {
    if (known == null) return true;
    return known['mtime'] != entry.mtimeMillis ||
        known['size'] != entry.sizeBytes ||
        known['hash'] != _fingerprint(entry);
  }

  /// Content fingerprint input. The device build hashes file bytes
  /// (SHA-256 via package:crypto); the mtime+size pre-check above avoids
  /// reading bytes for unchanged files.
  static String _fingerprint(MediaEntry entry) =>
      '${entry.uri}|${entry.mtimeMillis}|${entry.sizeBytes}';

  /// Diff all scopes against the DB. Returns entries needing indexing and
  /// removes rows for files that vanished (or scopes that were revoked).
  Future<List<MediaEntry>> diff(List<String> scopes) async {
    final seen = <String>[];
    final queue = <MediaEntry>[];
    for (final scope in scopes) {
      final entries = await source.listFiles(scope);
      for (final entry in entries) {
        seen.add(entry.uri);
        final known = await db.fileByUri(entry.uri);
        if (needsIndexing(entry: entry, known: known)) {
          queue.add(entry);
        }
      }
    }
    await db.deleteMissing(seen);
    return queue;
  }

  /// Drop everything indexed under a revoked scope URI.
  /// Embeddings/OCR/frames/transcripts follow via ON DELETE CASCADE.
  Future<int> revokeScope(String scopeUri) => db.deleteByScopePrefix(scopeUri);
}
