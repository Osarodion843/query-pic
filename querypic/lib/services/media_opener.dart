import 'dart:io';

import 'package:flutter/services.dart';

/// Opens a real on-device file in the system gallery / viewer.
///
/// Android goes through the `querypic/open` channel (FileProvider
/// content:// + read grant). Other platforms return false so callers can
/// fall back to `url_launcher`.
class MediaOpener {
  static const _channel = MethodChannel('querypic/open');

  /// Returns true when the system took the file. Throws [MediaOpenException]
  /// with a short user-safe message on failure (never a raw stack trace).
  static Future<bool> openFile(String path, {bool isVideo = false}) async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod<bool>(
        'openFile',
        {'path': path, 'isVideo': isVideo},
      );
      return true;
    } on PlatformException catch (e) {
      throw MediaOpenException(_friendly(e.code, e.message));
    }
  }

  static String _friendly(String code, String? cause) {
    final short = (cause ?? '').trim().split('\n').first.trim();
    return switch (code) {
      'NO_APP' => 'No gallery app found to open this file.',
      'OPEN_ARGS' => 'Could not open this file.',
      _ when short.isNotEmpty && short.length < 80 =>
        'Could not open in gallery app ($short).',
      _ => 'Could not open in gallery app.',
    };
  }
}

class MediaOpenException implements Exception {
  final String message;
  const MediaOpenException(this.message);
  @override
  String toString() => message;
}
