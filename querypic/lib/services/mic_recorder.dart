import 'dart:io';

import 'package:flutter/services.dart';

/// Push-to-talk query recording over the `querypic/mic` channel.
///
/// Records 16 kHz mono int16 WAV straight into the app cache (exactly what
/// the Whisper frontend consumes — no decode step). The caller owns the
/// returned file and must delete it after transcription: voice audio is
/// never indexed, never uploaded, never kept.
class MicRecorder {
  static const _channel = MethodChannel('querypic/mic');

  /// True on platforms with a recorder (Android today; iOS returns false
  /// so callers hide the mic affordance instead of failing).
  static bool get isSupported => true;

  /// Start recording. Returns the cache WAV path being written.
  /// Throws [MicException] with a short user-safe message.
  static Future<String> start() async {
    if (!Platform.isAndroid) {
      throw const MicException('Voice search needs Android for now.');
    }
    try {
      final path = await _channel.invokeMethod<String>('startRecording');
      if (path == null || path.isEmpty) throw const MicException('Mic failed to start.');
      return path;
    } on PlatformException catch (e) {
      throw MicException(
        switch (e.code) {
          'NO_PERMISSION' => 'Microphone permission denied.',
          _ => 'Mic failed to start.',
        },
      );
    } catch (_) {
      throw const MicException('Mic failed to start.');
    }
  }

  /// Stop recording. Returns the finished WAV path.
  static Future<String> stop() async {
    try {
      final path = await _channel.invokeMethod<String>('stopRecording');
      if (path == null || path.isEmpty) throw const MicException('Nothing was recording.');
      return path;
    } on PlatformException catch (_) {
      throw const MicException('Mic recording failed.');
    } catch (_) {
      throw const MicException('Mic recording failed.');
    }
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<bool>('cancelRecording');
    } catch (_) {}
  }
}

class MicException implements Exception {
  final String message;
  const MicException(this.message);
  @override
  String toString() => message;
}
