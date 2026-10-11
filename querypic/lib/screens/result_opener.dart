import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/handoff.dart';
import '../services/media_opener.dart';
import '../services/media_source.dart';
import '../services/query_engine.dart';

/// Shared native-gallery handoff (PRD §2): one implementation for the
/// workspace preview and the Similar preview (which shipped without any
/// open action at all — similar results were view-only).
/// Real files open through the `querypic/open` channel (FileProvider
/// content:// + read grant); http(s) falls back to url_launcher.
/// Free tier plays from 0s; Pro applies seek-to-frame via `?t=` where the
/// scheme supports it. Errors are one-line friendly messages, never traces.
Future<void> openRankedResult(
  BuildContext context,
  RankedResult result, {
  required bool isPro,
  double? seekOverride,
}) async {
  String? diskPath;
  var uriString = result.uri;
  final assetId = photoAssetIdFromUri(result.uri);
  if (assetId != null) {
    final asset = await AssetEntity.fromId(assetId);
    final file = await asset?.file;
    if (!context.mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That file is gone from the device (deleted after indexing). '
            'Re-run indexing from Settings to clean up.',
          ),
        ),
      );
      return;
    }
    diskPath = file.path;
    uriString = file.uri.toString();
  } else if (uriString.startsWith('file://')) {
    diskPath = Uri.tryParse(uriString)?.toFilePath();
  }
  // Real on-disk file: native gallery/player handoff first.
  if (diskPath != null && diskPath.isNotEmpty) {
    try {
      final opened =
          await MediaOpener.openFile(diskPath, isVideo: result.isVideo);
      if (opened) {
        final seekSecs = seekOverride ?? result.bestFrameSecs;
        if (isPro &&
            result.isVideo &&
            seekSecs != null &&
            seekSecs > 0 &&
            context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Matched moment ${formatSeek(seekSecs)}.',
              ),
            ),
          );
        }
        return;
      }
    } on MediaOpenException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return;
    }
    // Non-Android (channel unavailable): fall through to url_launcher.
  }
  final h = buildHandoff(
    uriString,
    startSecs: seekOverride ?? result.bestFrameSecs,
    isPro: isPro,
  );
  final uri = Uri.tryParse(h.launch);
  final scheme = uri?.scheme ?? '';
  final launchable = scheme == 'content' ||
      scheme == 'file' ||
      scheme == 'https' ||
      scheme == 'http';
  if (!launchable) {
    // Demo/scale seeds have no real bytes on disk (rows only).
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Demo row'),
        content: const Text(
          'Synthetic rows have no real file on disk. Native handoff '
          'runs on real indexed media (grant a folder in Settings → '
          'Indexed folders).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  try {
    await launchUrl(uri!, mode: LaunchMode.externalApplication);
    if (!h.seekApplied && h.seekSecs != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Matched moment ${formatSeek(h.seekSecs!)} — this player '
            'opens at the start.',
          ),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open in gallery app.'),
        ),
      );
    }
  }
}
