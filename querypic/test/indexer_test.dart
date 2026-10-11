import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/crawler.dart';
import 'package:querypic/services/guardrails.dart';
import 'package:querypic/services/index_database.dart';
import 'package:querypic/services/index_worker.dart';
import 'package:querypic/services/media_source.dart';

/// Pure-logic tests for the Phase 2 crawler/worker (host-runnable).
/// DB I/O paths are proven by tools/model_harness.py + tools/resume_check.py
/// against the same schema; device E2E (MediaStore source) runs on hardware.
void main() {
  const entry = MediaEntry(
    uri: 'scope/DCIM/img_0001.jpg',
    isVideo: false,
    mtimeMillis: 1700000000,
    sizeBytes: 2048,
  );
  Map<String, Object?> knownFor(MediaEntry e) => {
    'mtime': e.mtimeMillis,
    'size': e.sizeBytes,
    'hash': '${e.uri}|${e.mtimeMillis}|${e.sizeBytes}',
  };

  group('Crawler.needsIndexing', () {
    test('unknown file needs indexing', () {
      expect(Crawler.needsIndexing(entry: entry, known: null), isTrue);
    });

    test('identical mtime+size+hash is skipped', () {
      expect(
        Crawler.needsIndexing(entry: entry, known: knownFor(entry)),
        isFalse,
      );
    });

    test('changed mtime triggers reindex', () {
      const changed = MediaEntry(
        uri: 'scope/DCIM/img_0001.jpg',
        isVideo: false,
        mtimeMillis: 1700000001,
        sizeBytes: 2048,
      );
      expect(
        Crawler.needsIndexing(entry: changed, known: knownFor(entry)),
        isTrue,
      );
    });

    test('changed size triggers reindex', () {
      const changed = MediaEntry(
        uri: 'scope/DCIM/img_0001.jpg',
        isVideo: false,
        mtimeMillis: 1700000000,
        sizeBytes: 4096,
      );
      expect(
        Crawler.needsIndexing(entry: changed, known: knownFor(entry)),
        isTrue,
      );
    });

    test('same mtime+size but different hash triggers reindex', () {
      final tampered = Map<String, Object?>.from(knownFor(entry))
        ..['hash'] = 'tampered';
      expect(
        Crawler.needsIndexing(entry: entry, known: tampered),
        isTrue,
      );
    });
  });

  group('IndexProgress', () {
    test('fraction is done/total', () {
      const p = IndexProgress(
        done: 1240,
        total: 5000,
        status: IndexStatus.running,
      );
      expect(p.fraction, closeTo(0.248, 0.001));
      expect(p.label, 'Indexing 1240 of 5000…');
    });

    test('pause labels carry the reason', () {
      const battery = IndexProgress(
        done: 10,
        total: 100,
        status: IndexStatus.pausedBattery,
      );
      expect(battery.label, contains('battery below 20%'));

      const thermal = IndexProgress(
        done: 10,
        total: 100,
        status: IndexStatus.pausedThermal,
      );
      expect(thermal.label, contains('hot'));
    });

    test('zero total never divides by zero', () {
      const p = IndexProgress(
        done: 0,
        total: 0,
        status: IndexStatus.idle,
      );
      expect(p.fraction, 0);
    });
  });

  group('IndexDatabase.tokenizeForIndex', () {
    test('lowercases, splits, drops shorts, dedupes', () {
      expect(
        IndexDatabase.tokenizeForIndex('HOME Depot receipt \$84.17 x'),
        containsAll(['home', 'depot', 'receipt', '84', '17']),
      );
      expect(
        IndexDatabase.tokenizeForIndex('HOME Depot receipt \$84.17 x'),
        isNot(contains('x')),
      );
    });

    test('empty and punctuation-only input yields nothing', () {
      expect(IndexDatabase.tokenizeForIndex(''), isEmpty);
      expect(IndexDatabase.tokenizeForIndex('!!! ...'), isEmpty);
    });

    test('stemming collapses plurals and verb forms', () {
      // Index and query sides stem identically, so related forms meet.
      expect(
        IndexDatabase.tokenizeForIndex('following receipts sunsets'),
        {'follow', 'receipt', 'sunset'},
      );
      expect(
        IndexDatabase.tokenizeForIndex('follow receipt sunset'),
        {'follow', 'receipt', 'sunset'},
      );
      expect(IndexDatabase.tokenizeForIndex('running played stories'), {
        'run',
        'play',
        'story',
      });
      // Shorts and non-inflections survive untouched.
      expect(
        IndexDatabase.tokenizeForIndex('bus glass anime 84'),
        {'bus', 'glas', 'anime', '84'},
      );
    });

    test('matches the Python contract exactly', () {
      // tools/text_index.py::tokenize must produce this same set.
      final tokens = IndexDatabase.tokenizeForIndex(
        'Who sang Happy Birthday?!',
      );
      expect(
        tokens.toSet(),
        {'who', 'sang', 'happy', 'birthday'},
      );
    });
  });

  group('Guardrails.evaluate (Phase 6)', () {
    test('healthy vitals proceed', () {
      expect(
        Guardrails.evaluate(
          batteryPct: 80,
          charging: false,
          thermal: 0,
          freeDiskBytes: 8 * 1024 * 1024 * 1024,
        ),
        isNull,
      );
    });

    test('unknown readings never pause', () {
      expect(
        Guardrails.evaluate(
          batteryPct: null,
          charging: null,
          thermal: null,
          freeDiskBytes: null,
        ),
        isNull,
      );
    });

    test('low battery pauses unless charging', () {
      expect(
        Guardrails.evaluate(batteryPct: 15, charging: false),
        GuardDecision.pauseBattery,
      );
      expect(
        Guardrails.evaluate(batteryPct: 15, charging: true),
        isNull,
      );
      expect(
        Guardrails.evaluate(batteryPct: 20, charging: false),
        isNull,
      );
    });

    test('thermal serious pauses, light proceeds', () {
      expect(
        Guardrails.evaluate(thermal: 2),
        GuardDecision.pauseThermal,
      );
      expect(Guardrails.evaluate(thermal: 3), GuardDecision.pauseThermal);
      expect(Guardrails.evaluate(thermal: 1), isNull);
    });

    test('low disk stops regardless of charge', () {
      expect(
        Guardrails.evaluate(
          batteryPct: 100,
          charging: true,
          freeDiskBytes: 100 * 1024 * 1024,
        ),
        GuardDecision.pauseStorage,
      );
    });

    test('STT queue rule: manual or charging/idle, Pro only', () {
      expect(
        Guardrails.shouldTranscribeNow(isPro: false, manual: true),
        isFalse,
      );
      expect(
        Guardrails.shouldTranscribeNow(isPro: true, manual: true),
        isTrue,
      );
      expect(
        Guardrails.shouldTranscribeNow(isPro: true, charging: true),
        isTrue,
      );
      expect(
        Guardrails.shouldTranscribeNow(isPro: true, idle: true),
        isTrue,
      );
      expect(
        Guardrails.shouldTranscribeNow(isPro: true),
        isFalse,
      );
    });

    test('model cache unloads on pressure', () {
      ModelCache.markLoaded('clip-test', Object());
      expect(ModelCache.isEmpty, isFalse);
      ModelCache.unloadAll();
      expect(ModelCache.isEmpty, isTrue);
    });
  });
}
