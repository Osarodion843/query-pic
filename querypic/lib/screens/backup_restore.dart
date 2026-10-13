import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/account_backup.dart';

/// Shared backup-restore flow: file picker -> password -> import ->
/// result. Used by Settings (existing installs) and the first-run
/// Landing page (fresh installs / post-reset), so a backup restores
/// INSTEAD of creating a new account. Returns true when at least one
/// profile came back.
Future<bool> runBackupRestore(BuildContext context) async {
  List<PlatformFile> picked = const [];
  try {
    picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['qpbackup'],
    );
  } catch (_) {
    picked = const [];
  }
  if (picked.isEmpty || !context.mounted) return false;
  Uint8List? bytes;
  try {
    bytes = await picked.first.readAsBytes();
  } catch (_) {
    bytes = null;
  }
  if (bytes == null || !context.mounted) return false;
  final pw = TextEditingController();
  final password = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Restore backup'),
      content: TextField(
        controller: pw,
        decoration: const InputDecoration(
          labelText: 'Backup password',
          border: OutlineInputBorder(),
        ),
        obscureText: true,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(pw.text),
          child: const Text('Restore'),
        ),
      ],
    ),
  );
  final pwText = password ?? '';
  if (password == null || !context.mounted) return false;
  try {
    final result = await AccountBackup.importBackup(
      Uint8List.fromList(bytes),
      pwText,
    );
    if (!context.mounted) return result.profiles > 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore done'),
        content: Text(
          result.profiles == 0
              ? 'Backup opened, but it holds no profiles.'
              : '${result.profiles} profile(s), ${result.keys} settings '
                  'restored. Your media re-indexes from the restored '
                  'folders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    return result.profiles > 0;
  } catch (_) {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore failed'),
        content: const Text('Wrong password or a damaged backup file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    return false;
  } finally {
    // Delayed dispose: a dialog exit transition may still reference the
    // controller for a frame (premature dispose = red screen).
    unawaited(
      Future.delayed(const Duration(milliseconds: 300))
          .then((_) => pw.dispose()),
    );
  }
}
