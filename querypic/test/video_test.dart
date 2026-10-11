import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/debug_seed.dart';
import 'package:querypic/services/index_database.dart';
import 'package:querypic/services/media_source.dart';
import 'package:querypic/services/query_engine.dart';
import 'package:querypic/services/stt_indexer.dart';
import 'package:querypic/services/stub_embed.dart';
import 'package:querypic/services/video_indexer.dart';

/// Pure-logic tests for the Phase 4 video path (host-runnable).
/// DB-backed steps (insertFrames/frameVectorScan) are proven by
/// tools/phase4_check.py against the same schema; device E2E runs on
/// hardware with real CLIP frame vectors.
void main() {
  Map<int, Map<String, Object?>> files(
    List<int> ids, {
    String type = 'photo',
  }) =>
      {
        for (final id in ids)
          id: {
            'id': id,
            'uri': 'scope/${type}_$id.${type == 'video' ? 'mp4' : 'jpg'}',
            'type': type,
            'mtime': 1700000000 + id,
          },
      };

  group('VideoIndexer.sampleTimes (PRD §5)', () {
    test('nonsense durations yield no frames', () {
      expect(VideoIndexer.sampleTimes(null), isEmpty);
      expect(VideoIndexer.sampleTimes(0), isEmpty);
      expect(VideoIndexer.sampleTimes(-5), isEmpty);
      expect(VideoIndexer.sampleTimes(60, intervalSecs: 0), isEmpty);
      expect(VideoIndexer.sampleTimes(60, freeCapSecs: 0), isEmpty);
    });

    test('60s video samples every 2.5s starting at 0', () {
      final t = VideoIndexer.sampleTimes(60);
      expect(t.length, 24);
      expect(t.first, 0.0);
      expect(t[1], 2.5);
      expect(t.last, lessThan(60));
    });

    test('Free cap limits sampling to the first 5 minutes', () {
      final t = VideoIndexer.sampleTimes(305);
      expect(t.last, lessThan(300));
      expect(t.length, 120); // 0 .. 297.5 at 2.5s
      // A second pass at a shorter video stays inside its own duration.
      final short = VideoIndexer.sampleTimes(10);
      expect(short.last, 7.5);
    });

    test('middle thumb time is the thumbnail convention', () {
      expect(VideoIndexer.middleThumbTime(const []), isNull);
      final t = VideoIndexer.sampleTimes(60);
      expect(VideoIndexer.middleThumbTime(t), t[t.length ~/ 2]);
    });
  });

  group('IndexDatabase.cosineInt8', () {
    test('identical vectors score 1.0', () {
      final v = List<int>.filled(32, 200);
      expect(IndexDatabase.cosineInt8(v, v), closeTo(1.0, 1e-9));
    });

    test('opposite offsets score -1.0', () {
      final a = List<int>.filled(32, 129);
      final b = List<int>.filled(32, 127);
      expect(IndexDatabase.cosineInt8(a, b), closeTo(-1.0, 1e-9));
    });

    test('degenerate inputs return null', () {
      expect(IndexDatabase.cosineInt8([1, 2, 3], [1, 2]), isNull);
      expect(IndexDatabase.cosineInt8(const [], const []), isNull);
      // Zero variance (all zero-point) has no direction.
      final flat = List<int>.filled(32, 128);
      expect(IndexDatabase.cosineInt8(flat, flat), isNull);
    });
  });

  group('fuseAndRank frame fusion (Phase 4 task 2)', () {
    test('frame-only video scores on visual scale with bestFrameSecs', () {
      final out = fuseAndRank(
        tokenHits: {8: 1},
        vectorHits: {},
        frameHits: {7: (sim: 0.5, t: 12.5)},
        files: {
          ...files([8]),
          ...files([7], type: 'video'),
        },
      );
      expect(out.length, 2);
      final video = out.singleWhere((r) => r.fileId == 7);
      // Lone visual rows need query text context (id 8) — stub-era gate.
      expect(video.score, 75); // 100 * (0.5 + 1) / 2
      expect(video.matchedVia, contains('visual'));
      expect(video.bestFrameSecs, 12.5);
      expect(video.isVideo, isTrue);
    });

    test('text + frame fuse 60/40 like photo vectors', () {
      final out = fuseAndRank(
        tokenHits: {7: 2},
        vectorHits: {},
        frameHits: {7: (sim: 0.5, t: 5.0)},
        files: files([7], type: 'video'),
      );
      // 60 * (2/2) + 40 * (0.5 + 1) / 2 = 60 + 30
      expect(out.first.score, 90);
      expect(out.first.matchedVia, containsAll(['text', 'visual']));
      expect(out.first.bestFrameSecs, 5.0);
    });

    test('stronger frame beats weaker photo vector, time kept', () {
      final out = fuseAndRank(
        tokenHits: {},
        vectorHits: {7: 0.1},
        frameHits: {7: (sim: 0.9, t: 33.0)},
        files: files([7], type: 'video'),
      );
      expect(out.first.score, 95); // uses 0.9, not 0.1
      expect(out.first.bestFrameSecs, 33.0);
    });

    test('visual floor drops frame-only noise, text always survives', () {
      final out = fuseAndRank(
        tokenHits: {7: 1},
        vectorHits: {8: -0.5, 9: -0.9},
        frameHits: {10: (sim: -0.9, t: 1.0)},
        files: {
          ...files([7]),
          ...files([8]),
          ...files([9]),
          ...files([10], type: 'video'),
        },
        visualFloor: 50,
      );
      // Scores: 7 text-only 55+ (kept); 8 visual 25; 9 visual 5;
      // 10 frame-only 5 — the two below floor are gone.
      expect(out.map((r) => r.fileId), [7]);
    });

    test('date-filter callers can still pass only frame hits', () {
      // Video rows with no photo-level embedding (frames only) must still
      // reach filesByIds — coverage of the ids union. Id 4 supplies the
      // query text context the stub-era visual gate requires.
      final out = fuseAndRank(
        tokenHits: {4: 1},
        vectorHits: {},
        frameHits: {3: (sim: 0.2, t: 0.0)},
        files: {
          ...files([4]),
          ...files([3], type: 'video'),
        },
      );
      expect(out.map((r) => r.fileId), [4, 3]);
      expect(out.last.score, 60);
    });

    test('tie-flood: max-hit text window never crowds out an exact frame', () {
      // Device repro (tools/diag_ties.py): tokenSearch LIMIT-50 returned 50
      // rows all at th==max, so 55+45*share pinned every one at 100. The
      // exact frame match (also 100) became a 51-way tie for 50 slots and
      // lost — zero videos in results. Lone text now caps at 90.
      final tokenHits = {for (var i = 1; i <= 50; i++) i: 1};
      final out = fuseAndRank(
        tokenHits: tokenHits,
        vectorHits: {},
        frameHits: {99: (sim: 1.0, t: 42.0)},
        files: {
          ...files(List.generate(50, (i) => i + 1)),
          ...files([99], type: 'video'),
        },
        limit: 50,
      );
      expect(out.length, 50);
      expect(out.first.fileId, 99);
      expect(out.first.score, 100);
      expect(out.first.bestFrameSecs, 42.0);
      expect(out[1].score, 90);
      // Deterministic tie-break by fileId: id 50 is the one cut.
      expect(out.last.fileId, 49);
    });

    test('on equal scores a video ranks before a photo', () {
      // Video ids are seeded last (highest); an id-only tie-break would
      // always cut them in a flood. Both score 100 here (vh=1.0).
      final out = fuseAndRank(
        tokenHits: {},
        vectorHits: {1: 1.0},
        frameHits: {99: (sim: 1.0, t: 5.0)},
        files: {
          ...files([1]),
          ...files([99], type: 'video'),
        },
      );
      expect(out.map((r) => r.fileId), [99, 1]);
    });
  });

  group('SyntheticFrameExtractor', () {
    test('emits 32-dim deterministic vectors matching the stub embedder',
        () async {
      const ex = SyntheticFrameExtractor();
      const entry = MediaEntry(
        uri: 'demo://sample-videos/a.mp4',
        isVideo: true,
        mtimeMillis: 1700000000,
        sizeBytes: 1024,
        durationSecs: 60,
      );
      final times = VideoIndexer.sampleTimes(entry.durationSecs);
      final frames = await ex.extract(entry, times);
      expect(frames.length, times.length);
      expect(frames.first.vector.length, 32);
      // Deterministic: same uri+t re-extracts to the same vector.
      final again = await ex.extract(entry, [times.first]);
      expect(again.first.vector, frames.first.vector);
      // Wired through the shared stub hash (see stub_embed.dart) — the
      // per-dimension `& 0xFF` collapse it replaces capped the corpus at
      // <=256 distinct vectors and flooded scans at cos=1.0.
      expect(frames.first.vector, stubEmbedText('${entry.uri}@${times.first}', 32));
      // Different timestamps differ (frames aren't degenerate duplicates).
      expect(
        (await ex.extract(entry, [2.5])).first.vector,
        isNot(equals(frames.first.vector)),
      );
    },);
  });

  group('StubSttEngine (Phase 5, task 2)', () {
    test('per-video vocabulary with timestamps', () async {
      const engine = StubSttEngine();
      final segs = await engine.transcribe(
        const MediaEntry(
          uri: 'demo://sample-videos/birthday_party.mp4',
          isVideo: true,
          mtimeMillis: 0,
          sizeBytes: 0,
        ),
      );
      expect(segs.length, 3);
      expect(segs.first.tStart, 0);
      expect(segs.first.text, contains('birthday'));
      expect(
        segs.map((s) => s.text).join(' '),
        contains('happy birthday'),
      );
      final other = await engine.transcribe(
        const MediaEntry(
          uri: 'demo://sample-videos/hike_trail.mp4',
          isVideo: true,
          mtimeMillis: 0,
          sizeBytes: 0,
        ),
      );
      expect(other.map((s) => s.text).join(' '), contains('hike'));
      final none = await engine.transcribe(
        const MediaEntry(
          uri: 'demo://sample-videos/unknown_clip.mp4',
          isVideo: true,
          mtimeMillis: 0,
          sizeBytes: 0,
        ),
      );
      expect(none, isEmpty);
    });
  });

  group('demo video seed contract', () {    test('rows are well-formed and the cap case exists', () {
      expect(DemoSeed.videoRows.length, greaterThanOrEqualTo(3));
      for (final row in DemoSeed.videoRows) {
        expect(row.durationSecs, greaterThan(0));
        expect(row.scenes, isNotEmpty);
        expect(row.ocr, isNotEmpty);
      }
      // hike_trail.mp4 (305s) must exceed the 300s Free cap by design.
      expect(DemoSeed.videoRows.any((r) => r.durationSecs > 300), isTrue);
      // All rows must produce at least one sampled frame.
      for (final row in DemoSeed.videoRows) {
        expect(VideoIndexer.sampleTimes(row.durationSecs), isNotEmpty);
      }
    });

    test('video scope is independent and cleared with synthetic rows',
        () {
      expect(DemoSeed.videoScopePrefix, startsWith('demo://'));
      expect(DemoSeed.videoScopePrefix, isNot(DemoSeed.scopePrefix));
      expect(DemoSeed.videoScopePrefix, isNot(DemoSeed.scaleScopePrefix));
    });
  });
}
