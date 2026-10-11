/// Media enumeration contract (Phase 2, task 1).
///
/// The crawler only ever sees files through a [MediaSource]. The device build
/// injects a MediaStore/PhotoKit source limited to [ScopeStore] URIs; tests
/// and the host harness inject fakes. There is no code path that crawls the
/// whole disk: an empty scope list yields zero files.
class MediaEntry {
  final String uri;
  final bool isVideo;
  final int mtimeMillis;
  final int sizeBytes;
  final int? width;
  final int? height;
  final double? durationSecs;

  const MediaEntry({
    required this.uri,
    required this.isVideo,
    required this.mtimeMillis,
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationSecs,
  });
}

abstract class MediaSource {
  /// List files under a single granted scope URI.
  Future<List<MediaEntry>> listFiles(String scopeUri);
}

/// Placeholder until platform channels land (TODO(device)).
/// Returns no files, so the worker stays idle and the banner stays hidden.
class NoopMediaSource implements MediaSource {
  const NoopMediaSource();

  @override
  Future<List<MediaEntry>> listFiles(String scopeUri) async => const [];
}

/// Stable URI helpers for device assets. URIs look like `photoid://<id>`
/// so results can resolve thumbnails + native handoff without storing
/// platform paths (which die on reboot/remount).
String photoAssetUri(String id) => 'photoid://$id';

/// Returns the asset id for `photoid://` URIs, null otherwise (synthetic
/// demo rows, legacy scopes).
String? photoAssetIdFromUri(String uri) {
  const prefix = 'photoid://';
  if (!uri.startsWith(prefix) || uri.length <= prefix.length) return null;
  return uri.substring(prefix.length);
}

/// DEBUG/BENCHMARK ONLY — never ships real user data.
/// Generates [count] synthetic photo entries under any scope so the
/// on-device pipeline (worker + sqflite + batching) can be timed without
/// waiting for the MediaStore source. Used by Settings → benchmark.
class SyntheticMediaSource implements MediaSource {
  final int count;
  const SyntheticMediaSource({this.count = 200});

  @override
  Future<List<MediaEntry>> listFiles(String scopeUri) async {
    return List<MediaEntry>.generate(count, (i) {
      return MediaEntry(
        uri: '$scopeUri/bench_${i.toString().padLeft(5, '0')}.jpg',
        isVideo: false,
        mtimeMillis: 1700000000 + i,
        sizeBytes: 2048 + (i % 7),
        width: 4000,
        height: 3000,
      );
    });
  }
}
