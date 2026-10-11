import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../services/app_index.dart';
import '../services/consent_store.dart';
import '../services/photo_media_source.dart';
import '../services/scope_store.dart';
import 'home_search_screen.dart';

/// Pure selection math (unit-tested): the MediaStore "all media"
/// aggregate arrives with a blank name and is dropped from BOTH the
/// visible list and the selection — selecting it produced the
/// impossible "34 of 33 selected" state (blank counted, never shown).
({List<String> visible, Set<String> selected}) resolveFolderSelection({
  required List<String> saved,
  required List<String> albums,
  required bool firstRun,
}) {
  final visible = albums.where((a) => a.trim().isNotEmpty).toList();
  final selected = saved.where(visible.contains).toSet();
  if (firstRun && saved.isEmpty && visible.isNotEmpty) {
    selected.addAll(visible);
  }
  return (visible: visible, selected: selected);
}

/// Scoped album picker: real device albums behind the photo permission.
/// Nothing is crawled without explicit selection; revoking here drops the
/// album's rows via the crawler's delete-missing pass on next run.
class FolderPickerScreen extends StatefulWidget {
  final bool firstRun;
  const FolderPickerScreen({super.key, this.firstRun = false});

  @override
  State<FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends State<FolderPickerScreen> {
  List<String> _albums = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _denied = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await ScopeStore.getScopedUris();
    final state = await PhotoManagerMediaSource.permissionState();
    if (!state.hasAccess) {
      if (mounted) {
        setState(() {
          _selected.addAll(saved);
          _loading = false;
          _denied = true;
        });
      }
      return;
    }
    final albums = await PhotoManagerMediaSource.albumNames();
    if (!mounted) return;
    final resolved = resolveFolderSelection(
      saved: saved,
      albums: albums,
      firstRun: widget.firstRun,
    );
    setState(() {
      _albums = resolved.visible;
      // Keep prior selection for albums that still exist; first run with
      // zero selection defaults to everything (explicit, one tap to trim).
      _selected
        ..clear()
        ..addAll(resolved.selected);
      _loading = false;
    });
  }

  Future<void> _request() async {
    final ok = await PhotoManagerMediaSource.ensurePermission();
    if (!mounted) return;
    if (!ok) {
      setState(() => _denied = true);
      return;
    }
    setState(() {
      _loading = true;
      _denied = false;
    });
    await _load();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ScopeStore.setScopedUris(_selected.toList());
      if (widget.firstRun) {
        await ConsentStore.setOnboardingDone();
      }
      // Kick the indexer now so results appear without a second visit.
      // Fire-and-forget: the worker guards re-entry; failures surface in
      // the home banner, never as a red screen here.
      // The wired Home carries the live worker (banner) + dynamic chips —
      // a bare Home would show neither until the next restart.
      HomeSearchScreen next = const HomeSearchScreen();
      try {
        final app = await AppIndex.ensure();
        unawaited(app.worker.runOnce());
        next = HomeSearchScreen.wired(app.worker);
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => next),
        (_) => false,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.firstRun ? 'Choose folders to index' : 'Indexed folders',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _denied
              ? _deniedBody()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'QueryPic only scans albums you pick. '
                      'Nothing is crawled without your consent, and you can '
                      'revoke an album here at any time.',
                    ),
                    const SizedBox(height: 12),
                    if (_albums.isEmpty)
                      const Text(
                        'No photo albums found on this device yet. '
                        'Take a photo, then pull to come back here.',
                      )
                    else ...[
                      CheckboxListTile(
                        title: const Text('All photos & videos'),
                        subtitle: Text(
                          _selected.length == _albums.length
                              ? 'Everything selected'
                              : '${_selected.length} of ${_albums.length} selected',
                        ),
                        value: _selected.length == _albums.length &&
                            _albums.isNotEmpty,
                        tristate: true,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.addAll(_albums);
                          } else {
                            _selected.clear();
                          }
                        }),
                      ),
                      const Divider(),
                      for (final album in _albums)
                        CheckboxListTile(
                          title: Text(album),
                          value: _selected.contains(album),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(album);
                            } else {
                              _selected.remove(album);
                            }
                          }),
                        ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              widget.firstRun
                                  ? 'Index ${_selected.length} album${_selected.length == 1 ? '' : 's'}'
                                  : 'Save Changes',
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _deniedBody() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.photo_library_outlined, size: 64),
          const SizedBox(height: 16),
          const Text(
            'Photo access is off',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'QueryPic needs photo-library access to find your pictures. '
            'Your photos never leave this phone.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _request,
            child: const Text('Allow photo access'),
          ),
          const SizedBox(height: 8),
          const TextButton(
            onPressed: PhotoManager.openSetting,
            child: Text('Open system settings'),
          ),
        ],
      ),
    );
  }
}
