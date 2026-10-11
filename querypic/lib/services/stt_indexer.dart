import 'package:photo_manager/photo_manager.dart';

import 'guardrails.dart';
import 'index_database.dart';
import 'media_source.dart';
/// Spoken word segment with timestamps (Phase 5, task 2).
class SpeechSegment {
  final double tStart;
  final double tEnd;
  final String text;
  const SpeechSegment({
    required this.tStart,
    required this.tEnd,
    required this.text,
  });
}

/// On-device STT pipeline (Phase 5, task 2; PRD §3).
///
/// Device build loads `whisper_tiny.tflite` (1.0-1.5x realtime on mobile CPU);
/// until then the stub simulates transcription by emitting timed segments
/// for demo videos.
abstract class SttEngine {
  Future<List<SpeechSegment>> transcribe(MediaEntry entry);
  String get modelVersion;

  /// Same result as [transcribe], but heavy inference runs off the UI
  /// thread (background isolate) with per-chunk progress. Default falls
  /// back to [transcribe] (stub engines are already instant).
  Future<List<SpeechSegment>> transcribeStream(
    MediaEntry entry, {
    void Function(int chunk, double startSecs)? onChunk,
  }) =>
      transcribe(entry);
}

class StubSttEngine implements SttEngine {
  const StubSttEngine();
  @override
  String get modelVersion => 'stub-whisper-v0';

  @override
  Future<List<SpeechSegment>> transcribeStream(
    MediaEntry entry, {
    void Function(int chunk, double startSecs)? onChunk,
  }) =>
      transcribe(entry);

  /// Per-video spoken vocabulary (debug only): each demo video "says" its
  /// scene words across three ~10s segments, so phrase queries
  /// ("happy birthday") return timestamped hits on the right video —
  /// the Phase 5 STT exit criterion, measurable before Whisper-Tiny lands.
  static List<String> vocabFor(String uri) {
    final name = uri.split('/').last;
    if (name.contains('birthday')) {
      return ['happy birthday to you', 'cake and candles celebration', 'singing with friends tonight'];
    }
    if (name.contains('ocean')) {
      return ['ocean waves on the beach', 'sunset over the water', 'summer vacation footage'];
    }
    if (name.contains('office') || name.contains('standup')) {
      return ['team standup meeting', 'sprint board review', 'office deploy friday'];
    }
    if (name.contains('hike')) {
      return ['mountain hike trail', 'forest river view', 'camping under stars'];
    }
    return [];
  }

  @override
  Future<List<SpeechSegment>> transcribe(MediaEntry entry) async {
    final lines = vocabFor(entry.uri);
    if (lines.isEmpty) return [];
    return [
      for (var i = 0; i < lines.length; i++)
        SpeechSegment(
          tStart: i * 10.0,
          tEnd: i * 10.0 + 10,
          text: lines[i],
        ),
    ];
  }
}

/// Transcript indexing logic.
class SttIndexer {
  final IndexDatabase db;
  final SttEngine engine;
  SttIndexer({required this.db, required this.engine});
  Future<void> indexVideo(
    MediaEntry entry,
    int fileId, {
    void Function(int chunk)? onChunk,
  }) async {
    final segments = await engine.transcribeStream(
      entry,
      onChunk: onChunk == null ? null : (c, _) => onChunk(c),
    );
    await indexSegments(fileId, segments);
  }

  /// Index precomputed segments (Step 5 debug path: the caller already
  /// ran the real engine and measured timing itself).
  Future<void> indexSegments(
    int fileId,
    List<SpeechSegment> segments,
  ) async {
    if (segments.isEmpty) return;

    final batch = db.db.batch();
    // Clear old transcripts.
    batch.delete('transcripts', where: 'file_id = ?', whereArgs: [fileId]);
    batch.delete('tokens', where: 'ref_id = ? AND kind = ?', whereArgs: [fileId, 'transcript']);

    for (final seg in segments) {
      batch.insert('transcripts', {
        'file_id': fileId,
        't_start': seg.tStart,
        't_end': seg.tEnd,
        'text': seg.text,
      });
    }
    // Index tokens for transcript search — deduped ACROSS segments:
    // tokens.kind/token/ref_id is a PRIMARY KEY, and words like "the"
    // repeat in several segments of one video.
    final seen = <String>{};
    for (final seg in segments) {
      for (final token in IndexDatabase.tokenizeForIndex(seg.text)) {
        if (seen.add(token)) {
          batch.insert('tokens', {
            'kind': 'transcript',
            'token': token,
            'ref_id': fileId,
          });
        }
      }
    }
    await batch.commit(noResult: true);
  }
}

/// Background transcription queue (Phase 5, task 2 + Phase 6 rules).
/// The queue is derived, not stored: any video row without transcript rows
/// is pending — so it survives restarts with no extra table. Processing
/// honors [Guardrails.shouldTranscribeNow] unless [manual] (user tapped
/// "Transcribe"), and is Pro-gated.
class TranscriptionQueue {
  final IndexDatabase db;
  final SttEngine engine;
  TranscriptionQueue({required this.db, required this.engine});

  /// Video file ids with no transcript rows yet.
  Future<List<int>> pendingVideoIds({int limit = 100}) async {
    final rows = await db.db.rawQuery(
      'SELECT f.id AS id FROM files f '
      'LEFT JOIN transcripts t ON t.file_id = f.id '
      "WHERE f.type = 'video' AND t.file_id IS NULL "
      'GROUP BY f.id LIMIT ?',
      [limit],
    );
    return [for (final r in rows) r['id'] as int];
  }

  /// Transcribe pending videos. Returns files completed. Needs the file
  /// rows to rebuild [MediaEntry] inputs (URI + duration).
  /// [onProgress] fires with (done, total) after each video (and once at
  /// the start with (0, total)) so callers can render a counted progress
  /// bar instead of an endless spinner.
  Future<int> process({
    required bool isPro,
    bool? charging,
    bool? idle,
    bool manual = false,
    int limit = 5,
    void Function(int done, int total)? onProgress,
    void Function(int chunk)? onChunk,
  }) async {
    if (!Guardrails.shouldTranscribeNow(
      isPro: isPro,
      charging: charging,
      idle: idle,
      manual: manual,
    )) {
      return 0;
    }
    final ids = await pendingVideoIds(limit: limit);
    onProgress?.call(0, ids.length);
    final indexer = SttIndexer(db: db, engine: engine);
    var done = 0;
    for (final id in ids) {
      if (await transcribeOne(id, indexer: indexer, onChunk: onChunk)) {
        done++;
      }
      onProgress?.call(done, ids.length);
    }
    return done;
  }

  /// Transcribe one video row by id. Resolves `photoid://` URIs to the
  /// on-disk file first — the engine only reads real paths, so without
  /// this every library video transcribed to nothing (silent no-op).
  /// Returns true when segments were produced and indexed.
  Future<bool> transcribeOne(
    int fileId, {
    SttIndexer? indexer,
    void Function(int chunk)? onChunk,
  }) async {
    final files = await db.filesByIds({fileId});
    final file = files[fileId];
    if (file == null) return false;
    final entry = await entryForTranscription(
      file['uri'] as String,
      mtimeMillis: (file['mtime'] as int?) ?? 0,
      durationSecs: (file['duration'] as num?)?.toDouble(),
    );
    if (entry == null) return false;
    final ix = indexer ?? SttIndexer(db: db, engine: engine);
    final before = (await db.transcriptsForFile(fileId)).length;
    await ix.indexVideo(entry, fileId, onChunk: onChunk);
    final after = (await db.transcriptsForFile(fileId)).length;
    return after > before;
  }

  /// Build a transcribable entry for a file row. `photoid://` assets
  /// resolve through photo_manager to their file on disk; `file://` and
  /// absolute paths pass through. Null when the file is gone.
  static Future<MediaEntry?> entryForTranscription(
    String uri, {
    required int mtimeMillis,
    double? durationSecs,
  }) async {
    final assetId = photoAssetIdFromUri(uri);
    if (assetId == null) {
      return MediaEntry(
        uri: uri,
        isVideo: true,
        mtimeMillis: mtimeMillis,
        sizeBytes: 0,
        durationSecs: durationSecs,
      );
    }
    try {
      final asset = await AssetEntity.fromId(assetId);
      final file = await asset?.file;
      if (file == null) return null;
      return MediaEntry(
        uri: 'file://${file.path}',
        isVideo: true,
        mtimeMillis: mtimeMillis,
        sizeBytes: 0,
        durationSecs: durationSecs,
      );
    } catch (_) {
      return null;
    }
  }
}
