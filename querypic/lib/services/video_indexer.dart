import 'index_database.dart';
import 'media_source.dart';
import 'stub_embed.dart';

/// One sampled frame: timestamp + INT8 embedding vector.
class VideoFrame {
  final double tSecs;
  final List<int> vector;
  const VideoFrame({required this.tSecs, required this.vector});
}

/// Frame decoding behind an interface (Phase 4, task 1).
/// Device build decodes real pixels (video_thumbnail + CLIP image tower);
/// the synthetic stand-in keeps sampling math, caps, storage and fusion
/// real and measurable on any host.
abstract class FrameExtractor {
  /// Frames for [entry]; must already respect the caller's time budget.
  Future<List<VideoFrame>> extract(MediaEntry entry, List<double> times);
  String get modelVersion;
}

/// Deterministic pseudo-frames derived from URI + timestamp (debug only).
class SyntheticFrameExtractor implements FrameExtractor {
  const SyntheticFrameExtractor();

  @override
  String get modelVersion => 'synth-frames-v0';

  @override
  Future<List<VideoFrame>> extract(
    MediaEntry entry,
    List<double> times,
  ) async {
    return [
      for (final t in times)
        VideoFrame(tSecs: t, vector: _vec('${entry.uri}@$t')),
    ];
  }

  static List<int> _vec(String seed) => stubEmbedText(seed, 32);
}

/// Video indexing pipeline (Phase 4).
///
/// Sampling (PRD §5): 1 frame every [intervalSecs] (default 2.5s), capped at
/// [freeCapSecs] (default 300s = first 5 min for Free). Middle sampled frame
/// is the thumbnail convention: thumbs/<fileId>.jpg under the sandbox (no
/// schema change needed). Corrupt/unsupported files are skipped individually
/// and reported — one bad file never aborts the pass (task 4).
class VideoIndexer {
  final IndexDatabase db;
  final FrameExtractor extractor;
  final double intervalSecs;
  final double freeCapSecs;

  /// URIs skipped in the last run with their reasons (task 4 visibility).
  final Map<String, String> skipped = {};

  VideoIndexer({
    required this.db,
    this.extractor = const SyntheticFrameExtractor(),
    this.intervalSecs = 2.5,
    this.freeCapSecs = 300,
  });

  /// Sample timestamps for a duration. Pure — unit-tested.
  /// Always includes t=0; never exceeds the cap; empty for nonsense input.
  static List<double> sampleTimes(
    double? durationSecs, {
    double intervalSecs = 2.5,
    double freeCapSecs = 300,
  }) {
    if (durationSecs == null ||
        durationSecs <= 0 ||
        intervalSecs <= 0 ||
        freeCapSecs <= 0) {
      return [];
    }
    final budget = durationSecs < freeCapSecs ? durationSecs : freeCapSecs;
    final times = <double>[];
    var t = 0.0;
    while (t < budget) {
      times.add(double.parse(t.toStringAsFixed(2)));
      t += intervalSecs;
    }
    return times;
  }

  /// Middle-sampled-frame timestamp (thumbnail convention). Pure.
  static double? middleThumbTime(List<double> times) {
    if (times.isEmpty) return null;
    return times[times.length ~/ 2];
  }

  /// Index one video: sample, extract, store frames. Returns frames stored.
  /// Throws nothing — failures land in [skipped] (task 4).
  Future<int> indexVideo(MediaEntry entry) async {
    if (!entry.isVideo) {
      skipped[entry.uri] = 'not a video';
      return 0;
    }
    try {
      final times = sampleTimes(
        entry.durationSecs,
        intervalSecs: intervalSecs,
        freeCapSecs: freeCapSecs,
      );
      if (times.isEmpty) {
        skipped[entry.uri] = 'unknown or zero duration';
        return 0;
      }
      final frames = await extractor.extract(entry, times);
      final known = await db.fileByUri(entry.uri);
      if (known == null) {
        skipped[entry.uri] = 'file row missing — index photo pass first';
        return 0;
      }
      await db.insertFrames(
        known['id'] as int,
        {for (final f in frames) f.tSecs: f.vector},
      );
      skipped.remove(entry.uri);
      return frames.length;
    } catch (e) {
      // Corrupt file, HEVC without decoder, SD-card hiccup: skip, continue.
      skipped[entry.uri] = '$e';
      return 0;
    }
  }
}
