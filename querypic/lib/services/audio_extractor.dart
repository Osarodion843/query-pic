import 'package:flutter/services.dart';

/// PCM extraction over the `querypic/audio` channel (Phase 5 STT).
/// Android decodes via MediaCodec (see MainActivity.kt); iOS via
/// AVAssetReader (AppDelegate.swift, needs a Mac build check).
/// Missing plugin / errors yield null — callers fall back to the stub
/// engine, never crash.
class AudioExtractor {
  static const _channel = MethodChannel('querypic/audio');

  /// Raw decoder bytes with format metadata for [durSec] from
  /// [startSec]. Decoding/downmixing/resampling all happen in tested
  /// Dart (services/resample.dart); the channel only demuxes + decodes.
  /// Returns null when extraction is unavailable or fails. The [ext]
  /// version fingerprints the native extractor build (0 = pre-versioned
  /// code that never reported it).
  static Future<
      ({
        int sampleRate,
        int channels,
        int encoding,
        Uint8List pcm,
        int ext,
      })?> extractPcm(
    String path, {
    required double startSec,
    required double durSec,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>(
        'extractPcm',
        {'path': path, 'startSec': startSec, 'durSec': durSec},
      );
      if (m == null) return null;
      final bytes = m['pcm'] as Uint8List?;
      final rate = (m['sampleRate'] as num?)?.toInt();
      if (bytes == null || rate == null) return null;
      return (
        sampleRate: rate,
        channels: (m['channels'] as num?)?.toInt() ?? 0,
        encoding: (m['encoding'] as num?)?.toInt() ?? 2,
        pcm: bytes,
        ext: (m['ext'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      // Surface the native reason (missing file, no audio track, codec
      // failure) instead of an empty silence that looks like success.
      throw StateError('audio extract: ${e.message ?? e.code}');
    }
  }
}
