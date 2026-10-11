import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/app_index.dart';
import '../services/handoff.dart';
import '../services/index_database.dart';
import '../services/media_source.dart';
import '../services/pro_gate.dart';
import '../services/query_engine.dart';
import '../services/search_service.dart';
import '../services/stt_indexer.dart';
import '../theme.dart';
import 'paywall_sheet.dart';
import 'folder_picker_screen.dart';
import 'result_opener.dart';
import 'similar_screen.dart';

/// Expanded media workspace (Phase 3, tasks 1-3; Phase 4 video).
/// Grid of matches with score badges, date filter row, preview modal.
/// Without a [search] backend (indexer hasn't run) it shows the empty state
/// instead of fake results. Native-player handoff opens the system player
/// (Free tier: from 0s — Phase 5 adds seek-to-frame).
class WorkspaceScreen extends StatefulWidget {
  final String query;
  final SearchService? search;
  const WorkspaceScreen({super.key, required this.query, this.search});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  static const _ranges = <String?>[null, 'Today', 'Past week', 'Past month'];
  String? _activeRange;
  List<RankedResult>? _results;
  String? _error;
  bool _loading = true;

  /// Free-tier fuzzy preview (Phase 5, task 4+6): label + feature for the
  /// lock chip; tapping it opens the paywall sheet.
  String? _previewLabel;
  ProFeature? _previewFeature;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // Explicit backend wins (tests, previews); otherwise use the app index
    // once its sandbox DB has opened.
    final SearchService backend =
        widget.search ?? (await AppIndex.ensure()).search;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      int? from;
      switch (_activeRange) {
        case 'Today':
          from = midnight.millisecondsSinceEpoch;
        case 'Past week':
          from = midnight
              .subtract(const Duration(days: 7))
              .millisecondsSinceEpoch;
        case 'Past month':
          from = DateTime(midnight.year, midnight.month - 1, 1)
              .millisecondsSinceEpoch;
      }
      // No explicit chip: run through the tier-aware path so Free fuzzy
      // queries surface the paywall preview instead of silently filtering.
      final List<RankedResult> results;
      ProFeature? preview;
      if (from != null) {
        results = await backend.searchWithRange(
          widget.query,
          fromMillis: from,
        );
      } else {
        final outcome = await backend.searchDetailed(widget.query, now: now);
        results = outcome.results;
        preview = outcome.preview;
      }
      if (!mounted) return;
      final parsed = prepareQuery(widget.query, now: now);
      setState(() {
        _results = results;
        _loading = false;
        _previewFeature = preview;
        _previewLabel = preview != null
            ? (parsed.filter.label ?? 'Smart date')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('"${widget.query}"')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                for (final r in _ranges)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(r ?? 'All dates'),
                      selected: _activeRange == r,
                      onSelected: (_) {
                        setState(() => _activeRange = r);
                        _run();
                      },
                    ),
                  ),
              ],
            ),
          ),
          _previewChip(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// Inline Pro preview chip (Phase 5, task 6): shown when a Free query
  /// parsed fuzzy-temporal. Tapping opens the paywall; subscribing reruns
  /// the search with the filter applied.
  Widget _previewChip() {
    final label = _previewLabel;
    final feature = _previewFeature;
    if (label == null || feature == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ActionChip(
        avatar: const Icon(Icons.lock_outline, size: 16),
        label: Text('Pro preview: $label'),
        onPressed: () async {
          final backend = widget.search ?? (await AppIndex.ensure()).search;
          if (!mounted) return;
          final subscribed = await showPaywallSheet(
            context,
            feature: feature,
            gate: backend.gate,
          );
          if (subscribed && mounted) _run();
        },
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _empty('Search failed', _error!);
    }
    final results = _results ?? [];
    if (results.isEmpty) {
      return _empty(
        'No matches',
        'If your library is still indexing, wait for the banner on Home. '
        'Otherwise try different words — or check which albums QueryPic '
        'is allowed to scan.',
        actionLabel: 'Choose folders',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FolderPickerScreen()),
        ),
        suggestions: true,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: results.length,
      itemBuilder: (context, i) => _ResultCard(
        result: results[i],
        onTap: () => _preview(results[i]),
      ),
    );
  }

  Widget _empty(String title, String hint,
      {String? actionLabel, VoidCallback? onAction, bool suggestions = false,}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: QueryPicColors.badgeTextLight,
                  ),
            ),
            if (suggestions) _suggestionChips(),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }

  /// Dead-end rescue: typo fixes ("did you mean?") plus words the index
  /// actually contains, so a miss teaches the library's vocabulary
  /// instead of shrugging.
  Widget _suggestionChips() {
    return FutureBuilder<({Set<String> vocab, List<String> top})>(
      future: () async {
        final db = AppIndex.current?.db;
        if (db == null) return (vocab: const <String>{}, top: const <String>[]);
        // Length-window the vocabulary around the longest query token:
        // typo fixes live within ±2 chars, and an unbounded cap can
        // truncate the alphabet before reaching them.
        var longest = 0;
        for (final t in IndexDatabase.tokenizeForIndex(widget.query)) {
          if (t.length > longest) longest = t.length;
        }
        final minLen = (longest - 2) < 3 ? 3 : longest - 2;
        return (
          vocab: await db.vocabulary(
            'ocr',
            limit: 2000,
            minLen: minLen,
            maxLen: longest + 2,
          ),
          top: await db.topTokens('ocr', limit: 5),
        );
      }(),
      builder: (context, snap) {
        final vocab = snap.data?.vocab ?? const <String>{};
        final top = snap.data?.top ?? const <String>[];
        // Results were empty, so every query token effectively missed.
        final fixes = <String>[];
        for (final t in IndexDatabase.tokenizeForIndex(widget.query)) {
          for (final s in didYouMean(t, vocab)) {
            if (!fixes.contains(s)) fixes.add(s);
          }
          if (fixes.length >= 3) break;
        }
        final words = top.where((w) => !fixes.contains(w)).toList();
        if (fixes.isEmpty && words.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            children: [
              if (fixes.isNotEmpty) ...[
                Text(
                  'Did you mean:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    for (final w in fixes)
                      ActionChip(
                        label: Text(w),
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => WorkspaceScreen(query: w),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (words.isNotEmpty) ...[
                Text(
                  fixes.isEmpty
                      ? 'Words in your library:'
                      : 'Or try:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    for (final w in words)
                    ActionChip(
                      label: Text(w),
                      onPressed: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => WorkspaceScreen(query: w),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _preview(RankedResult result) {
    final isPro = AppIndex.current?.search.gate.isPro ?? false;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _PreviewSheet(
        result: result,
        isPro: isPro,
        onFindSimilar: () {
          Navigator.of(context).pop();
          _findSimilar(result);
        },
      ),
    );
  }

  Future<void> _findSimilar(RankedResult result) async {
    final backend = widget.search ?? (await AppIndex.ensure()).search;
    final resolved = resolveSimilar(isPro: backend.gate.isPro);
    if (!resolved.allowed) {
      if (!mounted) return;
      final subscribed = await showPaywallSheet(
        context,
        feature: resolved.preview!,
        gate: backend.gate,
      );
      if (!subscribed || !mounted) return;
    }
    if (!mounted) return;
    final outcome = await backend.findSimilarById(result.fileId);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SimilarScreen(
          queryLabel: 'Similar to ${result.uri.split('/').last}',
          results: outcome.results,
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final RankedResult result;
  final VoidCallback onTap;
  const _ResultCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final band = result.band;
    final pill = band == ScoreBand.high
        ? const Color(0xFF16A34A)
        : band == ScoreBand.mid
            ? const Color(0xFFD97706)
            : const Color(0xFF6B7280);
    final assetId = photoAssetIdFromUri(result.uri);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: QueryPicColors.borderLight),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (assetId != null)
              FutureBuilder<AssetEntity?>(
                future: AssetEntity.fromId(assetId),
                builder: (context, snap) {
                  final asset = snap.data;
                  if (asset == null) return const _ThumbFallback();
                  return FutureBuilder<Uint8List?>(
                    future: asset.thumbnailDataWithSize(
                      const ThumbnailSize.square(300),
                    ),
                    builder: (context, thumb) {
                      final bytes = thumb.data;
                      if (bytes == null) return const _ThumbFallback();
                      return Image.memory(bytes, fit: BoxFit.cover);
                    },
                  );
                },
              )
            else
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: result.isVideo
                        ? const [Color(0xFFA5B4FC), Color(0xFF22D3EE)]
                        : const [Color(0xFFDDD6FE), Color(0xFFA5B4FC)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Center(
                  child: Text(
                    result.isVideo ? '▶' : '🖼️',
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              ),
            if (result.isVideo)
              const Positioned(
                left: 6,
                bottom: 6,
                child: Icon(Icons.videocam, size: 16, color: Colors.white),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: pill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${result.score}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while a device thumbnail loads or when the asset is gone
/// (deleted since indexing — the next worker pass drops the row).
class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: QueryPicColors.chipTintLight,
      child: const Center(
        child: Icon(Icons.image_outlined, color: Colors.grey),
      ),
    );
  }
}

class _PreviewSheet extends StatelessWidget {
  final RankedResult result;
  final bool isPro;
  final VoidCallback? onFindSimilar;
  const _PreviewSheet({
    required this.result,
    this.isPro = false,
    this.onFindSimilar,
  });

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(result.mtime);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  result.uri.split('/').last,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _ScorePill(score: result.score),
            ],
          ),
          const SizedBox(height: 8),
          _TranscriptView(
            fileId: result.fileId,
            isPro: isPro,
            onSeek: (secs) async {              if (!isPro) {
                final backend = await AppIndex.ensure();
                if (!context.mounted) return;
                await showPaywallSheet(
                  context,
                  feature: ProFeature.transcript,
                  gate: backend.search.gate,
                );
                return;
              }
              await _openNative(
                context,
                result,
                isPro: isPro,
                seekOverride: secs,
              );
            },
          ),
          // One-tap speech indexing for videos without transcripts (Pro).
          // Previously transcription hid in Settings, so videos silently
          // never became searchable by spoken words.
          _TranscribeButton(result: result, isPro: isPro),
          const SizedBox(height: 8),
          Text(
            '${result.isVideo ? 'Video' : 'Photo'} · '
            '${date.year}-${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')} · '
            'matched via ${result.matchedVia.join(' + ')}'
            '${result.bestFrameSecs != null ? ' · frame ${result.bestFrameSecs}s' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openNative(context, result, isPro: isPro),
              icon: const Icon(Icons.play_arrow),
              label: Text(_playLabel()),
            ),
          ),
          if (result.isVideo) ...[
            const SizedBox(height: 8),
            // Honest seek UI: the Pro seek note appears only when a real
            // timestamp exists (matched frame or transcript tap). Without
            // frame rows (real videos in the stub era) there is nothing to
            // seek to, so Pro just plays and Free sees the generic upsell.
            if (isPro && (result.bestFrameSecs ?? 0) > 0)
              Text(
                'Pro seek: opens at the matched frame when the player '
                'supports it (?t=).',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else if (!isPro)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Free tier plays from the start (0s).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final backend = await AppIndex.ensure();
                      if (!context.mounted) return;
                      final subscribed = await showPaywallSheet(
                        context,
                        feature: ProFeature.seekToFrame,
                        gate: backend.search.gate,
                      );
                      if (subscribed && context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.lock_outline, size: 16),
                    label: const Text('Pro seek'),
                  ),
                ],
              ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onFindSimilar,
              icon: Icon(isPro ? Icons.image_search : Icons.lock_outline),
              label: Text(isPro ? 'Find similar' : 'Find similar (Pro)'),
            ),
          ),
          ],
        ),
      ),
    );
  }

  /// Pro play label carries the seek target (Phase 5, task 1).
  String _playLabel() {
    final t = result.bestFrameSecs;
    if (result.isVideo && isPro && t != null && t > 0) {
      return 'Play from ${formatSeek(t)} (Pro)';
    }
    return result.isVideo ? 'Open in native player' : 'Open in gallery app';
  }

  /// Native handoff delegates to the shared opener (used by the Similar
  /// preview too) so every result opens identically everywhere.
  Future<void> _openNative(
    BuildContext context,
    RankedResult result, {
    required bool isPro,
    double? seekOverride,
  }) =>
      openRankedResult(
        context,
        result,
        isPro: isPro,
        seekOverride: seekOverride,
      );
}

class _ScorePill extends StatelessWidget {
  final int score;
  const _ScorePill({required this.score});

  @override
  Widget build(BuildContext context) {
    final band = bandFor(score);
    final color = band == ScoreBand.high
        ? const Color(0xFF16A34A)
        : band == ScoreBand.mid
            ? const Color(0xFFD97706)
            : const Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$score% match',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _TranscriptView extends StatelessWidget {
  final int fileId;
  final bool isPro;
  final Future<void> Function(double secs) onSeek;
  const _TranscriptView({
    required this.fileId,
    required this.isPro,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: AppIndex.current?.db.transcriptsForFile(fileId),
      builder: (context, snapshot) {
        final rows = snapshot.data;
        if (rows == null || rows.isEmpty) return const SizedBox.shrink();
        // Cap visible rows: long transcripts scrolled the sheet into
        // overflow (1476px on device). The sheet itself scrolls now;
        // this keeps previews glanceable.
        const maxRows = 4;
        final shown = rows.take(maxRows).toList();
        final hidden = rows.length - shown.length;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black12,
            borderRadius: BorderRadius.circular(8),
          ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TRANSCRIPT',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 4),
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0 &&
                      (shown[i]['t_start'] as num).toDouble() -
                              (shown[i - 1]['t_end'] as num)
                                  .toDouble() >=
                          15)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '· · · no confident speech in between · · ·',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  InkWell(
                    onTap: () =>
                        onSeek((shown[i]['t_start'] as num).toDouble()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatSeek(
                              (shown[i]['t_start'] as num).toDouble(),
                            ),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              shown[i]['text'] as String,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!isPro)
                            const Icon(Icons.lock_outline, size: 14),
                        ],
                      ),
                    ),
                  ),
                ],
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '+$hidden more',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// One-tap transcription for a video without transcript rows.
/// Free tier gets the paywall; Pro transcribes in place (minutes on
/// debug builds) and pops the sheet so the transcript shows on reopen.
class _TranscribeButton extends StatefulWidget {
  final RankedResult result;
  final bool isPro;
  const _TranscribeButton({required this.result, required this.isPro});

  @override
  State<_TranscribeButton> createState() => _TranscribeButtonState();
}

class _TranscribeButtonState extends State<_TranscribeButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.result.isVideo) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, Object?>>>(
      future: AppIndex.current?.db.transcriptsForFile(widget.result.fileId),
      builder: (context, snap) {
        final rows = snap.data;
        // Still loading, or already transcribed: nothing to offer.
        if (rows == null || rows.isNotEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _transcribe,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      widget.isPro
                          ? Icons.mic_outlined
                          : Icons.lock_outline,
                      size: 16,
                    ),
              label: Text(
                _busy
                    ? 'Transcribing…'
                    : widget.isPro
                        ? 'Transcribe speech'
                        : 'Transcribe speech (Pro)',
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _transcribe() async {
    if (!widget.isPro) {
      final backend = await AppIndex.ensure();
      if (!mounted) return;
      await showPaywallSheet(
        context,
        feature: ProFeature.stt,
        gate: backend.search.gate,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final app = await AppIndex.ensure();
      final ok = await TranscriptionQueue(db: app.db, engine: app.stt)
          .transcribeOne(widget.result.fileId);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Speech transcribed — search spoken words now.'
                : 'No speech found in this video.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcription failed for this video.'),
        ),
      );
    }
  }
}
