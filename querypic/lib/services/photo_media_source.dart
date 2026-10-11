import 'package:photo_manager/photo_manager.dart';

import 'media_source.dart';

/// Device media source (photo_manager / MediaStore).
///
/// Scopes are album names as shown in the folder picker; the special scope
/// `'all'` covers every album. Unknown scopes yield zero files (never a
/// full-disk crawl by accident).
///
/// Listing is metadata-only (no file-byte reads): id, type, dates and
/// dimensions come from the MediaStore row, so even 10k-file libraries
/// enumerate in seconds. Content bytes are only ever touched by the
/// feature extractor / transcriber for files being indexed.
class PhotoManagerMediaSource implements MediaSource {
  static const scopeAll = 'all';
  static const _pageSize = 100;

  const PhotoManagerMediaSource();

  /// Request extended photo+video access. Returns true when the app may
  /// enumerate assets (full or limited/partial access).
  static Future<bool> ensurePermission() async {
    final state = await PhotoManager.requestPermissionExtend();
    return state.hasAccess;
  }

  /// Current permission state without prompting (for picker copy).
  static Future<PermissionState> permissionState() async {
    return PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    );
  }

  /// Album names for the folder picker, most-items first.
  static Future<List<String>> albumNames() async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      onlyAll: false,
    );
    final names = albums.map((a) => a.name).toSet().toList()..sort();
    return names;
  }

  @override
  Future<List<MediaEntry>> listFiles(String scopeUri) async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      onlyAll: false,
    );
    final wanted = albums.where((a) {
      if (scopeUri == scopeAll) return true;
      return a.name == scopeUri;
    }).toList();
    final out = <MediaEntry>[];
    for (final album in wanted) {
      var page = 0;
      while (true) {
        final assets = await album.getAssetListPaged(page: page, size: _pageSize);
        if (assets.isEmpty) break;
        for (final asset in assets) {
          final entry = entryForAsset(asset);
          if (entry != null) out.add(entry);
        }
        if (assets.length < _pageSize) break;
        page++;
      }
    }
    return out;
  }

  /// Pure mapping: MediaStore row -> [MediaEntry]. Null for non-photo/video
  /// rows (audio etc.), which QueryPic never indexes.
  static MediaEntry? entryForAsset(AssetEntity asset) {
    final isVideo = asset.type == AssetType.video;
    if (!isVideo && asset.type != AssetType.image) return null;
    final mtime = asset.modifiedDateTime.millisecondsSinceEpoch;
    return MediaEntry(
      uri: photoAssetUri(asset.id),
      isVideo: isVideo,
      mtimeMillis: mtime,
      sizeBytes: 0, // metadata-only listing; crawler hashes uri|mtime|size
      width: asset.width,
      height: asset.height,
      durationSecs: isVideo ? asset.duration.toDouble() : null,
    );
  }
}
