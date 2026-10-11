import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/handoff.dart';
import 'package:querypic/services/index_database.dart';
import 'package:querypic/services/pro_gate.dart';
import 'package:querypic/services/query_engine.dart';
import 'package:querypic/services/search_service.dart';

/// Pure-logic tests for the Phase 3 query path (host-runnable).
/// DB-backed steps (tokenSearch/vectorScan/filesByIds) are proven by
/// tools/phase3_check.py against the same SQL; device E2E runs on hardware.
void main() {
  Map<int, Map<String, Object?>> files(List<int> ids) => {
        for (final id in ids)
          id: {
            'id': id,
            'uri': 'scope/img_$id.jpg',
            'type': 'photo',
            'mtime': 1700000000 + id,
          },
      };

  group('bandFor', () {
    test('bands match the design system', () {
      expect(bandFor(95), ScoreBand.high);
      expect(bandFor(80), ScoreBand.high);
      expect(bandFor(79), ScoreBand.mid);
      expect(bandFor(50), ScoreBand.mid);
      expect(bandFor(49), ScoreBand.low);
    });
  });

  group('parseDateFilter', () {
    final now = DateTime(2026, 10, 2, 15, 0);

    test('today bounds at midnight', () {
      final f = parseDateFilter('receipt from today', now: now);
      expect(f.isActive, isTrue);
      expect(f.fromMillis, DateTime(2026, 10, 2).millisecondsSinceEpoch);
      expect(f.admits(DateTime(2026, 10, 2, 9).millisecondsSinceEpoch),
          isTrue,);
      expect(f.admits(DateTime(2026, 10, 1, 9).millisecondsSinceEpoch),
          isFalse,);
    });

    test('yesterday is a 24h window', () {
      final f = parseDateFilter('photos from yesterday', now: now);
      expect(f.label, 'Yesterday');
      expect(f.admits(DateTime(2026, 10, 1, 12).millisecondsSinceEpoch),
          isTrue,);
      expect(f.admits(DateTime(2026, 10, 2).millisecondsSinceEpoch),
          isFalse,);
    });

    test('last week spans 7 days', () {
      final f = parseDateFilter('beach sunset from last week', now: now);
      expect(f.label, 'Past week');
      expect(f.admits(DateTime(2026, 9, 26).millisecondsSinceEpoch),
          isTrue,);
      expect(f.admits(DateTime(2026, 9, 20).millisecondsSinceEpoch),
          isFalse,);
    });

    test('no keywords means no constraint', () {
      final f = parseDateFilter('dog on grass', now: now);
      expect(f.isActive, isFalse);
      expect(f.admits(0), isTrue);
    });
  });

  group('stripDateKeywords + prepareQuery', () {
    test('date words leave the token query', () {
      expect(stripDateKeywords('beach sunset from last week'),
          'beach sunset from',);
    });

    test('prepareQuery splits filter from tokens', () {
      final p = prepareQuery('receipt from today',
          now: DateTime(2026, 10, 2, 15),);
      expect(p.filter.isActive, isTrue);
      expect(p.tokens, isNot(contains('today')));
      expect(p.tokens, contains('receipt'));
    });
  });

  group('fuseAndRank', () {
    test('text-only hits rank by share with visible floor', () {
      final out = fuseAndRank(
        tokenHits: {1: 3, 2: 1},
        vectorHits: {},
        files: files([1, 2]),
      );
      expect(out.map((r) => r.fileId), [1, 2]);
      // Capped at 90 so exact visual/frame evidence (100) outranks lone text.
      expect(out.first.score, 90);
      expect(out.first.matchedVia, contains('text'));
      expect(out.last.score, greaterThanOrEqualTo(55));
    });

    test('visual-only hits rank by similarity when text context exists', () {
      final out = fuseAndRank(
        tokenHits: {3: 1},
        vectorHits: {1: 0.9, 2: -0.5},
        files: files([1, 2, 3]),
      );
      expect(out.map((r) => r.fileId), [1, 3, 2]);
      expect(out.first.score, 95);
      expect(out.first.matchedVia, contains('visual'));
    });

    test('visual-only noise without text context is dropped', () {
      // A top-K scan always fills K rows; without query text behind them
      // the noise tail (~75-85) must not leak into results.
      final empty = fuseAndRank(
        tokenHits: {},
        vectorHits: {1: 0.6, 2: 0.7},
        files: files([1, 2]),
      );
      expect(empty, isEmpty);
      // Near-exact matches survive without context (exact scene tag).
      final kept = fuseAndRank(
        tokenHits: {},
        vectorHits: {1: 1.0},
        files: files([1]),
      );
      expect(kept.single.score, 100);
    });

    test('CLIP-era gate admits meaning, drops noise (visualMinSim)', () {
      // Real CLIP vectors separate: matches ~0.25+, random pairs ~0.05-0.15.
      final matched = fuseAndRank(
        tokenHits: {},
        vectorHits: {1: 0.3, 2: 0.1},
        files: files([1, 2]),
        visualFloor: 50,
        visualMinSim: SearchService.clipVisualMinSim,
      );
      expect(matched.map((r) => r.fileId), [1]);
      expect(matched.single.score, 65); // 100 * (0.3 + 1) / 2
      expect(matched.single.matchedVia, contains('visual'));
      // Gibberish stays a clean empty state.
      final gibberish = fuseAndRank(
        tokenHits: {},
        vectorHits: {1: 0.12, 2: 0.08},
        files: files([1, 2]),
        visualFloor: 50,
        visualMinSim: SearchService.clipVisualMinSim,
      );
      expect(gibberish, isEmpty);
    });

    test('dual signals fuse 60/40 and sort', () {
      final out = fuseAndRank(
        tokenHits: {1: 1, 2: 3},
        vectorHits: {1: 0.9, 2: -0.9},
        files: files([1, 2]),
      );
      // id 2: max(90 lone, 60*1 + 40*0.05 = 62) = 90;
      // id 1: max(55 + 35/3 = 67, 60*(1/3) + 40*0.95 = 58) = 67
      expect(out.map((r) => r.fileId), [2, 1]);
      expect(out.first.score, 90);
      expect(out.last.score, 67);
      expect(out.first.matchedVia, containsAll(['text', 'visual']));
    });

    test('weak visual never drags down strong text', () {
      // Device repro (tools/diag_stt.py --transcribe-library): a 3/4
      // text match with a 0.099 frame sim scored 67 (dual blend) and was
      // cut; as text-only it scores 81 and survives.
      final out = fuseAndRank(
        tokenHits: {1: 3, 2: 4},
        vectorHits: {1: 0.099},
        files: files([1, 2]),
      );
      expect(out.map((r) => r.fileId), [2, 1]);
      expect(out.first.score, 90);
      // max(55 + 35*0.75 = 81 lone, 45 + 22 = 67 blend) = 81 (was 67)
      expect(out.last.score, 81);
      expect(out.last.matchedVia, containsAll(['text', 'visual']));
    });

    test('unknown ids are dropped, output is limited', () {
      final out = fuseAndRank(
        tokenHits: {1: 2, 999: 9},
        vectorHits: {},
        files: files([1]),
        limit: 1,
      );
      expect(out.length, 1);
      expect(out.first.fileId, 1);
    });
  });

  group('expandQuery', () {
    test('adds indexed synonyms, never removes user words', () {
      final out = expandQuery('anime party');
      expect(out, contains('anime'));
      expect(out, contains('party'));
      expect(out, contains('cartoon')); // anime -> cartoon
      expect(out, contains('celebration')); // party -> celebration
    });

    test('unknown words pass through untouched', () {
      expect(expandQuery('zxqvkw'), 'zxqvkw');
      expect(expandQuery(''), '');
    });

    test('stemmed plurals still expand', () {
      // 'parties' stems to 'party' before lookup.
      expect(expandQuery('parties'), contains('celebration'));
    });
  });

  group('editDistance + didYouMean', () {
    test('editDistance counts simply with a cap', () {
      expect(editDistance('receipt', 'receipt'), 0);
      expect(editDistance('reciept', 'receipt'), 2);
      expect(editDistance('anime', 'animal'), 2);
      expect(editDistance('a', 'abcdefghij'), greaterThan(3));
    });

    test('didYouMean rescues typos, ignores known words', () {
      const vocab = {'receipt', 'sunset', 'beach', 'birthday'};
      expect(didYouMean('reciept', vocab), contains('receipt'));
      expect(didYouMean('receipt', vocab), isEmpty);
      expect(didYouMean('an', vocab), isEmpty); // too short
      expect(didYouMean('zxqvkw', vocab), isEmpty); // nothing close
    });
  });

  group('StubTextEmbedder', () {
    test('distinct texts yield distinct, decorrelated vectors', () async {
      const e = StubTextEmbedder();
      final samples = [
        'birthday', 'ocean', 'meeting', 'hike', 'sunset',
        'receipt', 'passport', 'invoice', 'cake', 'waves',
      ];
      final vecs = <String, List<int>>{};
      for (final s in samples) {
        vecs[s] = await e.embed(s);
        expect(vecs[s]!.length, 32);
      }
      // The old stub masked state to 8 bits per dimension: <=256 vectors
      // total, so ~78 of 20k rows tied every query at cos=1.0 and flooded
      // the top-K scans (device: vecTop=[1.00], modes={visual:49}).
      expect(vecs.values.toSet().length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        for (var j = i + 1; j < samples.length; j++) {
          final c = IndexDatabase.cosineInt8(
            vecs[samples[i]]!,
            vecs[samples[j]]!,
          );
          expect(c, isNotNull);
          expect(
            c!,
            lessThan(0.9),
            reason: '${samples[i]} vs ${samples[j]}',
          );
        }
      }
    });

    test('same text embeds byte-identically (query == seeded row)', () async {
      const e = StubTextEmbedder();
      expect(await e.embed('birthday'), await e.embed('birthday'));
      // Scene-tag frame rows (debug_seed) hit 1.00 only when both sides
      // share this exact function.
      expect(await e.embed('ocean'), await e.embed('ocean'));
    });
  });

  group('fuzzy temporal parsing (Phase 5, task 4)', () {
    // now = 2026-10-02 (October, autumn).
    final now = DateTime(2026, 10, 2, 15, 0);
    int ms(DateTime d) => d.millisecondsSinceEpoch;

    test('last summer resolves to the completed Jun-Aug window', () {
      final f = parseDateFilter('sunset from last summer', now: now);
      expect(f.fuzzy, isTrue);
      expect(f.label, 'Summer 2026');
      expect(f.fromMillis, ms(DateTime(2026, 6, 1)));
      expect(f.toMillis, ms(DateTime(2026, 9, 1)) - 1);
    });

    test('this summer in-season clamps to now', () {
      final inSummer = DateTime(2026, 7, 15);
      final f = parseDateFilter('this summer', now: inSummer);
      expect(f.fuzzy, isTrue);
      expect(f.label, 'Summer 2026');
      expect(f.fromMillis, ms(DateTime(2026, 6, 1)));
      expect(f.toMillis, ms(inSummer));
    });

    test('this summer post-season resolves to the full window', () {
      final f = parseDateFilter('this summer', now: now);
      expect(f.fromMillis, ms(DateTime(2026, 6, 1)));
      expect(f.toMillis, ms(DateTime(2026, 9, 1)) - 1);
    });

    test('bare season in-season is partial', () {
      final f = parseDateFilter('autumn light', now: now);
      expect(f.fuzzy, isTrue);
      expect(f.label, 'Autumn 2026');
      expect(f.fromMillis, ms(DateTime(2026, 9, 1)));
      expect(f.toMillis, ms(now));
    });

    test('bare winter out-of-season resolves to last winter', () {
      final f = parseDateFilter('winter cabin', now: now);
      expect(f.label, 'Winter 2025');
      expect(f.fromMillis, ms(DateTime(2025, 12, 1)));
      expect(f.toMillis, ms(DateTime(2026, 3, 1)) - 1);
    });

    test('last winter mid-winter resolves to the completed one', () {
      final f = parseDateFilter(
        'last winter snow',
        now: DateTime(2026, 1, 15),
      );
      expect(f.label, 'Winter 2024');
      expect(f.fromMillis, ms(DateTime(2024, 12, 1)));
    });

    test('this winter before December falls back to the most recent', () {
      final f = parseDateFilter(
        'this winter',
        now: DateTime(2026, 7, 10),
      );
      expect(f.label, 'Winter 2025');
      expect(f.fromMillis, ms(DateTime(2025, 12, 1)));
      expect(f.toMillis, ms(DateTime(2026, 3, 1)) - 1);
    });

    test('fall is an autumn alias', () {
      final f = parseDateFilter('fall colors', now: now);
      expect(f.label, 'Fall 2026');
      expect(f.fromMillis, ms(DateTime(2026, 9, 1)));
    });

    test('recent, last year and this year', () {
      final r = parseDateFilter('recent birthday', now: now);
      expect(r.fuzzy, isTrue);
      expect(r.label, 'Recent');
      expect(r.fromMillis, ms(DateTime(2026, 9, 2)));
      final ly = parseDateFilter('last year beach', now: now);
      expect(ly.label, 'Past year');
      expect(ly.fromMillis, ms(DateTime(2025, 10, 2)));
      final ty = parseDateFilter('this year wedding', now: now);
      expect(ty.label, 'This year');
      expect(ty.fromMillis, ms(DateTime(2026, 1, 1)));
    });

    test('free keywords stay non-fuzzy', () {
      expect(parseDateFilter('beach today', now: now).fuzzy, isFalse);
      expect(parseDateFilter('dog on grass', now: now).fuzzy, isFalse);
    });

    test('scaffolding stripped, bare season kept as token', () {
      final p = prepareQuery('sunset from last summer', now: now);
      expect(p.filter.fuzzy, isTrue);
      expect(p.tokens, contains('sunset'));
      expect(p.tokens, isNot(contains('summer')));
      expect(p.tokens, isNot(contains('last')));
      final bare = prepareQuery('summer haze', now: now);
      expect(bare.filter.fuzzy, isTrue);
      expect(bare.tokens, contains('summer'));
      final r = prepareQuery('recent birthday', now: now);
      expect(r.tokens, 'birthday');
    });
  });

  group('resolveFilter + ProGate (Phase 5, task 6)', () {
    test('Free fuzzy runs unconstrained with preview flag', () {
      const fuzzy = DateFilter(
        fromMillis: 1,
        label: 'Summer 2026',
        fuzzy: true,
      );
      final r = resolveFilter(parsed: fuzzy, isPro: false);
      expect(r.filter.isActive, isFalse);
      expect(r.preview, ProFeature.fuzzyTemporal);
    });

    test('Pro fuzzy applies the filter with no preview', () {
      const fuzzy = DateFilter(
        fromMillis: 1,
        label: 'Summer 2026',
        fuzzy: true,
      );
      final r = resolveFilter(parsed: fuzzy, isPro: true);
      expect(r.filter.label, 'Summer 2026');
      expect(r.preview, isNull);
    });

    test('non-fuzzy passes through on both tiers', () {
      const plain = DateFilter(fromMillis: 1, label: 'Today');
      expect(
        resolveFilter(parsed: plain, isPro: false).filter.label,
        'Today',
      );
      expect(
        resolveFilter(parsed: plain, isPro: false).preview,
        isNull,
      );
    });

    test('gate matrix: Free denies, Pro allows every feature', () {
      final free = ProGate();
      final pro = ProGate(isPro: true);
      for (final f in ProFeature.values) {
        expect(free.canUse(f), isFalse);
        expect(pro.canUse(f), isTrue);
      }
    });

    test('resolveSimilar: Free blocks with preview, Pro allows', () {
      expect(resolveSimilar(isPro: false).allowed, isFalse);
      expect(resolveSimilar(isPro: false).preview, ProFeature.visualSimilarity);
      expect(resolveSimilar(isPro: true).allowed, isTrue);
      expect(resolveSimilar(isPro: true).preview, isNull);
    });
  });

  group('buildHandoff (Phase 5, task 1)', () {
    test('Free always opens the raw uri', () {
      final h = buildHandoff(
        'https://x.com/v.mp4',
        startSecs: 42,
        isPro: false,
      );
      expect(h.launch, 'https://x.com/v.mp4');
      expect(h.seekApplied, isFalse);
    });

    test('Pro http appends ?t=', () {
      final h = buildHandoff(
        'https://cdn.example.com/v/birthday.mp4',
        startSecs: 42,
        isPro: true,
      );
      expect(h.launch, 'https://cdn.example.com/v/birthday.mp4?t=42');
      expect(h.seekApplied, isTrue);
    });

    test('Pro content scheme keeps uri with hint', () {
      final h = buildHandoff(
        'content://media/video/1',
        startSecs: 42,
        isPro: true,
      );
      expect(h.launch, 'content://media/video/1');
      expect(h.seekApplied, isFalse);
      expect(h.seekSecs, 42);
      expect(formatSeek(90), '1:30');
    });

    test('null or zero start means no seek', () {
      expect(
        buildHandoff('https://x.com/v.mp4', isPro: true).seekApplied,
        isFalse,
      );
      expect(
        buildHandoff(
          'https://x.com/v.mp4',
          startSecs: 0,
          isPro: true,
        ).seekApplied,
        isFalse,
      );
    });
  });
}
