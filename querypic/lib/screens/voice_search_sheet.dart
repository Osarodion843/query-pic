import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_index.dart';
import '../services/media_source.dart';
import '../services/mic_recorder.dart';
import '../services/stt_indexer.dart';
import 'workspace_screen.dart';

/// Push-to-talk voice search sheet.
///
/// Flow: permission (runtime, only here) -> tap record -> speak (15 s cap)
/// -> on-device Whisper transcription -> text lands as the gallery query.
/// The WAV is deleted right after transcription: voice audio is never
/// indexed, stored, or uploaded — it exists only to become query text.
class VoiceSearchSheet extends StatefulWidget {
  const VoiceSearchSheet({super.key});

  @override
  State<VoiceSearchSheet> createState() => _VoiceSearchSheetState();
}

enum _Phase { permission, ready, recording, transcribing, done, error }

class _VoiceSearchSheetState extends State<VoiceSearchSheet> {
  _Phase _phase = _Phase.permission;
  String _message = 'Checking microphone access…';
  String _transcript = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ensurePermission();
  }

  Future<void> _ensurePermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) {
      if (mounted) {
        setState(() {
          _phase = _Phase.ready;
          _message = 'Tap the mic and describe a photo or video.';
        });
      }
      return;
    }
    final asked = await Permission.microphone.request();
    if (!mounted) return;
    setState(() {
      if (asked.isGranted) {
        _phase = _Phase.ready;
        _message = 'Tap the mic and describe a photo or video.';
      } else if (asked.isPermanentlyDenied) {
        _phase = _Phase.error;
        _message = 'Mic blocked. Allow microphone access in system '
            'Settings to use voice search.';
      } else {
        _phase = _Phase.error;
        _message = 'Microphone permission is needed for voice search.';
      }
    });
  }

  Future<void> _toggleRecord() async {
    if (_busy) return;
    if (_phase == _Phase.recording) {
      await _stopAndTranscribe();
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      await MicRecorder.start();
      if (!mounted) return;
      setState(() {
        _phase = _Phase.recording;
        _message = 'Listening… tap again to stop (15 s max).';
        _busy = false;
      });
    } on MicException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _stopAndTranscribe() async {
    setState(() {
      _busy = true;
      _phase = _Phase.transcribing;
      _message = 'Transcribing on-device…';
    });
    String wavPath;
    try {
      wavPath = await MicRecorder.stop();
    } on MicException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = e.message;
        _busy = false;
      });
      return;
    }
    try {
      final app = await AppIndex.ensure();
      final engine = app.stt;
      if (engine is StubSttEngine) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.error;
          _message = 'Voice model is missing on this install — '
              'text search still works.';
          _busy = false;
        });
        return;
      }
      final segs = await engine.transcribeStream(
        MediaEntry(
          uri: wavPath,
          isVideo: false,
          mtimeMillis: DateTime.now().millisecondsSinceEpoch,
          sizeBytes: 0,
        ),
      );
      final text = segs.map((s) => s.text.trim()).join(' ').trim();
      if (!mounted) return;
      if (text.isEmpty) {
        setState(() {
          _phase = _Phase.error;
          _message = 'Heard nothing clear — try again, closer to the mic.';
          _busy = false;
        });
      } else {
        setState(() {
          _phase = _Phase.done;
          _transcript = text;
          _message = 'Heard: "$text"';
          _busy = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = engineUnavailable();
        _busy = false;
      });
    } finally {
      // Voice audio never persists: delete the WAV either way.
      try {
        await File(wavPath).delete();
      } catch (_) {}
    }
  }

  String engineUnavailable() =>
      'Voice transcription is unavailable right now.';

  @override
  void dispose() {
    if (_phase == _Phase.recording) MicRecorder.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = _phase == _Phase.recording;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Voice search',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(_message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (_phase == _Phase.transcribing)
            const CircularProgressIndicator()
          else
            IconButton.filled(
              iconSize: 36,
              onPressed: (_phase == _Phase.ready || recording) && !_busy
                  ? _toggleRecord
                  : null,
              icon: Icon(recording ? Icons.stop : Icons.mic),
              style: IconButton.styleFrom(
                backgroundColor: recording ? Colors.red : null,
                padding: const EdgeInsets.all(20),
              ),
            ),
          if (_phase == _Phase.done) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkspaceScreen(query: _transcript),
                    ),
                  );
                },
                icon: const Icon(Icons.search),
                label: const Text('Search for this'),
              ),
            ),
          ],
          if (_phase == _Phase.error && _transcript.isEmpty) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() {
                  _phase = _Phase.ready;
                  _message = 'Tap the mic and describe a photo or video.';
                });
              },
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens the voice search sheet. Stub STT (no Whisper assets) transcribes
/// to nothing — the sheet then explains instead of failing silently.
Future<void> showVoiceSearchSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const VoiceSearchSheet(),
  );
}
