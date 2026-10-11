import 'dart:async';
import 'dart:typed_data';

import 'crawler.dart';
import 'guardrails.dart';
import 'index_database.dart';
import 'media_source.dart';
import 'pro_gate.dart';
import 'scope_store.dart';
import 'stub_embed.dart';

/// Worker status surfaced to the progress banner (Phase 2, task 3).
enum IndexStatus { idle, running, pausedBattery, pausedThermal, pausedStorage, pausedCap, done }

class IndexProgress {
  final int done;
  final int total;
  final IndexStatus status;
  final String? reason;
  const IndexProgress({
    required this.done,
    required this.total,
    required this.status,
    this.reason,
  });

  double get fraction => total == 0 ? 0 : done / total;

  /// Banner copy per Journey Phase 2 (progress + pause reason).
  /// Every pause names WHAT paused (background indexing of new media)
  /// and what keeps working (search over everything indexed so far) —
  /// "Paused" alone left users guessing.
  String get label {
    switch (status) {
      case IndexStatus.running:
        return 'Indexing $done of $total…';
      case IndexStatus.pausedBattery:
        return 'Paused indexing (battery below 20%) — search still works · '
            'resumes when charging';
      case IndexStatus.pausedThermal:
        return 'Paused indexing (device is hot) — search still works · '
            'resumes when cool';
      case IndexStatus.pausedStorage:
        return 'Stopped indexing (less than 1 GB free) — search still '
            'works · free space to resume';
      case IndexStatus.pausedCap:
        return 'Free library full (10,000 files) — search still works · '
            'upgrade to keep indexing';
      case IndexStatus.done:
        return 'Index up to date ($total files)';
      case IndexStatus.idle:
        return '';
    }
  }
}

/// Battery/thermal gate (Phase 2, task 3 + PRD §6 guardrails).
/// The device build reads BatteryManager/thermal APIs; until then the worker
/// never pauses on its own. Returning a reason pauses AFTER the current batch
/// commits — interruption can never corrupt the index.
abstract class PauseSignals {
  /// Null = proceed; non-null = pause with this status.
  Future<IndexStatus?> check();
}

class NoopPauseSignals implements PauseSignals {
  const NoopPauseSignals();
  @override
  Future<IndexStatus?> check() async => null;
}

/// Device-backed pause signals (Phase 6): reads battery/thermal/disk over
/// the `querypic/vitals` channel and maps the pure [Guardrails] decision
/// to a banner status. Unknown readings never pause (see Guardrails).
class DevicePauseSignals implements PauseSignals {
  const DevicePauseSignals();
  @override
  Future<IndexStatus?> check() async {
    final v = await MethodChannelVitals.read();
    switch (Guardrails.evaluate(
      batteryPct: v.batteryPct,
      charging: v.charging,
      thermal: v.thermal,
      freeDiskBytes: v.freeDiskBytes,
    )) {
      case null:
        return null;
      case GuardDecision.pauseBattery:
        return IndexStatus.pausedBattery;
      case GuardDecision.pauseThermal:
        return IndexStatus.pausedThermal;
      case GuardDecision.pauseStorage:
        return IndexStatus.pausedStorage;
    }
  }
}

/// Feature extraction behind an interface (Phase 2, task 2).
/// Device build plugs in CLIP (TFLite/CoreML) + platform OCR + EXIF here.
/// The stub keeps the pipeline, batching, DB writes and UI real today.
class IndexFeatures {
  final List<int> vector;
  final String ocrText;
  const IndexFeatures({required this.vector, this.ocrText = ''});
}

abstract class FeatureExtractor {
  Future<IndexFeatures> extract(MediaEntry entry);
  String get modelVersion;
}

class StubFeatureExtractor implements FeatureExtractor {
  const StubFeatureExtractor();
  @override
  String get modelVersion => 'stub-v0';

  @override
  Future<IndexFeatures> extract(MediaEntry entry) async {
    // Deterministic 32-d placeholder derived from the URI (shared stub hash
    // — full-width state, see stub_embed.dart).
    final vec = stubEmbedText(entry.uri, 32);
    return IndexFeatures(vector: Uint8List.fromList(vec));
  }
}

/// Background index worker (Phase 2, tasks 1-4).
///
/// Search stays usable while this runs: task 4 falls out naturally because
/// FTS/vector rows commit per batch and queries read committed rows only.
class IndexWorker {
  final MediaSource source;
  final IndexDatabase db;
  final FeatureExtractor extractor;
  final PauseSignals pauses;
  final int batchSize;

  /// Tier gate for the Free 10k cap (Phase 7, task 1). Null = uncapped
  /// (tests, benchmarks).
  final ProGate? gate;
  final int freeCap;

  final _controller = StreamController<IndexProgress>.broadcast();
  Stream<IndexProgress> get progress => _controller.stream;

  /// Last emitted progress (broadcast streams don't replay: screens that
  /// subscribe mid-run would otherwise show nothing until the next event).
  IndexProgress? _last;
  IndexProgress? get lastProgress => _last;

  bool _running = false;

  /// URI -> error for files that failed in the last run (Phase 6 offline
  /// queue: failures never abort the pass; the next runOnce re-emits them
  /// via crawler diff, which is the persistent retry queue).
  final Map<String, String> lastErrors = {};

  IndexWorker({
    required this.source,
    required this.db,
    this.extractor = const StubFeatureExtractor(),
    this.pauses = const NoopPauseSignals(),
    this.batchSize = 50,
    this.gate,
    this.freeCap = 10000,
  });

  /// Full pass over current scopes. Re-entrant calls are ignored.
  Future<void> runOnce() async {
    if (_running) return;
    _running = true;
    try {
      final scopes = await ScopeStore.getScopedUris();
      final crawler = Crawler(source: source, db: db);
      final queue = await crawler.diff(scopes);
      final total = queue.length;
      var done = 0;
      lastErrors.clear();
      // Phase 7 Free cap: hard-stop at freeCap real files with a
      // friendly banner state (pausedCap). Pro bypasses.
      if (gate != null &&
          !gate!.isPro &&
          await db.realFileCount() >= freeCap) {
        _emit(done, total, IndexStatus.pausedCap, null);
        return;
      }
      _emit(done, total, IndexStatus.running, null);

      for (var i = 0; i < queue.length; i += batchSize) {
        final pause = await pauses.check();
        if (pause != null) {
          _emit(done, total, pause, null);
          return; // resume later; committed batches are skipped by diff
        }
        final batch = queue.sublist(
          i,
          (i + batchSize > queue.length) ? queue.length : i + batchSize,
        );
        for (final entry in batch) {
          try {
            final features = await extractor.extract(entry);
            await db.insertIndexed(
              uri: entry.uri,
              isVideo: entry.isVideo,
              mtime: entry.mtimeMillis,
              size: entry.sizeBytes,
              width: entry.width,
              height: entry.height,
              duration: entry.durationSecs,
              hash: '${entry.uri}|${entry.mtimeMillis}|${entry.sizeBytes}',
              vector: features.vector,
              modelVer: extractor.modelVersion,
              ocrText: features.ocrText,
            );
          } catch (e) {
            lastErrors[entry.uri] = '$e';
          }
          done++;
        }
        _emit(done, total, IndexStatus.running, null);
      }
      _emit(done, total, IndexStatus.done, null);
    } finally {
      _running = false;
    }
  }

  void _emit(int done, int total, IndexStatus status, String? reason) {
    if (!_controller.isClosed) {
      _last = IndexProgress(
        done: done,
        total: total,
        status: status,
        reason: reason,
      );
      _controller.add(_last!);
    }
  }

  Future<void> dispose() => _controller.close();
}
