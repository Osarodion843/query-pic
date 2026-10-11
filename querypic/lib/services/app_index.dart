import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'clip_joint.dart';
import 'index_database.dart';
import 'index_worker.dart';
import 'mlkit_labels.dart';
import 'photo_media_source.dart';
import 'pro_gate.dart';
import 'search_service.dart';
import 'stt_indexer.dart';
import 'tflite_stt.dart';

/// App-wide index backend (Phase 3 device wiring).
///
/// Owns the sandbox DB (`index.db` in app documents), the background worker
/// and the search service. The media source is the real device library
/// (photo_manager / MediaStore) limited to [ScopeStore] album scopes;
/// search reads whatever the worker has committed.
/// Safe to call [ensure] multiple times; concurrently callers share one open.
class AppIndex {
  final IndexDatabase db;
  final IndexWorker worker;
  final SearchService search;

  /// CLIP joint tower when its model file was found (null = stub era).
  /// Surfaced in Settings → Model status for device confirmation.
  final ClipJoint? clip;

  /// Speech engine: real TFLite Whisper when its assets load, stub
  /// otherwise (Step 5 wiring; stub keeps every path measurable).
  final SttEngine stt;

  static AppIndex? _current;
  static Future<AppIndex>? _opening;

  AppIndex._(this.db, this.worker, this.search, this.stt, [this.clip]);

  static AppIndex? get current => _current;

  /// Full local wipe support (Accounts -> Reset everything): close the DB
  /// and drop all memoized state so the next ensure() reopens fresh AFTER
  /// the caller deletes prefs/files. Without this the old (deleted) DB
  /// handle would keep serving.
  static Future<void> resetForWipe() async {
    final opening = _opening;
    _opening = null;
    _current = null;
    try {
      final app = await opening;
      await app?.db.db.close();
    } catch (_) {}
  }

  static Future<AppIndex> ensure() {
    _opening ??= _open();
    return _opening!;
  }

  static Future<AppIndex> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final db = await IndexDatabase.open('${dir.path}/index.db');
    final gate = ProGate();
    gate.isPro = await ProTierStore.isPro();
    // Step 5 CLIP: real joint tower ONLY when the user opted in AND the
    // crash fuse is intact. Rationale: a native (SIGSEGV-class) load
    // failure kills the process past any try/catch, so a bad model must
    // never sit on the startup path. Fuse protocol (fsync file, NOT
    // prefs — prefs increments die unflushed with the process): increment
    // before the load, reset after success; two consecutive process deaths
    // disarm CLIP until the user re-enables it.
    final prefs = await SharedPreferences.getInstance();
    // CLIP semantic search defaults ON when the model file is present:
    // free-text descriptions only match by meaning with real embeddings.
    // The crash fuse (2 strikes) + fail-closed load keep low-end devices
    // safe — a failed load silently keeps ML Kit labels + stub vectors.
    final useClip = prefs.getBool('querypic_use_clip') ?? true;
    var crashes = await ClipFuse.read(dir.path);
    final joint = ClipJoint();
    // Default: ML Kit labels (Step 5B) — real photo contents as searchable
    // text. CLIP replaces both sides when opted in and loadable.
    FeatureExtractor extractor = MlKitPhotoExtractor();
    TextEmbedder embedder = const StubTextEmbedder();
    var clipOk = false;
    // Missing file is NOT a crash: only arm the fuse when there is a model
    // to load. (Previously every launch without the adb-pushed file burned
    // a strike, disarming CLIP with fuse=2/2 before it ever ran.)
    final modelFile = useClip && crashes < 2
        ? await ClipJoint.findModelFile()
        : null;
    if (modelFile != null) {
      ClipFuse.writeSync(dir.path, crashes + 1);
      // Bisect stage (Developer tools): map-only proves whether the
      // segfault lives in load/mmap (dies) or inference (survives).
      final mapOnly = prefs.getBool('querypic_clip_maponly') ?? false;
      clipOk = await joint.loadStaged(runProbe: !mapOnly);
      if (clipOk) {
        // Reset the fuse ONLY when the probe inference survived (not on
        // map-only loads): a load that succeeds but an inference that
        // segfaults must keep its strikes, or the worker-loop death repeats
        // forever with the fuse pinned at 0 (observed: 199s uptime death on
        // itel S666LN, fuse reset by the successful load).
        if (!mapOnly) {
          crashes = 0;
          ClipFuse.writeSync(dir.path, 0);
        }
        extractor = ClipImageExtractor(joint);
        embedder = ClipTextEmbedder(joint);
      }
    }
    if (prefs.getString('querypic_model_ver') != extractor.modelVersion) {
      await db.clearIndex();
      await prefs.setString('querypic_model_ver', extractor.modelVersion);
    }
    // Device-visible diagnostics (logcat I/flutter): the Model status row
    // shows the same, but logcat proves it without UI taps.
    if (clipOk) {
      debugPrint('QueryPic CLIP loaded: ${joint.tensorInfo}');
    } else {
      debugPrint('QueryPic CLIP skipped: useClip=$useClip '
          'fuse=$crashes/2 err=${joint.lastError} '
          'tried=${ClipJoint.triedPaths.join(',')}');
    }
    final worker = IndexWorker(
      source: const PhotoManagerMediaSource(), // real device library.
      db: db,
      extractor: extractor,
      pauses: const DevicePauseSignals(), // Phase 6 guardrails.
      gate: gate, // Phase 7 Free 10k cap.
    );
    final search = SearchService(
      db: db,
      embedder: embedder,
      gate: gate,
    );
    SttEngine stt = const StubSttEngine();
    try {
      final real = TfliteSttEngine();
      if (await real.load()) stt = real;
    } catch (_) {
      stt = const StubSttEngine();
    }
    _current = AppIndex._(db, worker, search, stt, clipOk ? joint : null);
    return _current!;
  }
}
