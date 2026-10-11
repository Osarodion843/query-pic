import 'package:flutter/material.dart';
import '../services/app_index.dart';
import '../services/index_worker.dart';
import '../services/scope_store.dart';
import '../theme.dart';

/// Indexing progress banner (Phase 2, task 3; Journey Phase 2).
/// Running: "Indexing 1,240 of 5,000…" + bar. Paused: amber + reason.
/// Done/idle: reassurance line with the indexed-file count and scoped
/// folders, so it's always clear whether the library is fully indexed.
/// Theme-aware (dark surfaces in dark mode).
class IndexBanner extends StatelessWidget {
  final Stream<IndexProgress> progress;

  /// Last known progress for late subscribers (see [IndexWorker.lastProgress]).
  final IndexProgress? initial;
  const IndexBanner({super.key, required this.progress, this.initial});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<IndexProgress>(
      stream: progress,
      initialData: initial,
      builder: (context, snapshot) {
        final p = snapshot.data;
        final dark = Theme.of(context).brightness == Brightness.dark;
        if (p == null || p.status == IndexStatus.idle) {
          return _CountsLine(dark: dark, compact: true);
        }
        final paused = p.status == IndexStatus.pausedBattery ||
            p.status == IndexStatus.pausedThermal ||
            p.status == IndexStatus.pausedStorage ||
            p.status == IndexStatus.pausedCap;
        final running = p.status == IndexStatus.running;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: paused
                ? const Color(0xFFFEF3C7)
                : dark
                    ? QueryPicColors.surfaceDark
                    : Colors.white,
            border: Border.all(
              color: paused
                  ? const Color(0xFFF59E0B)
                  : dark
                      ? QueryPicColors.borderDark
                      : const Color(0xFFE2E8F0),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (paused
                        ? '⏸️ '
                        : running
                            ? '⚙️ '
                            : '✅ ') +
                    p.label,
                style: TextStyle(
                  fontSize: 12,
                  color: paused
                      ? const Color(0xFF92400E)
                      : dark
                          ? const Color(0xFFF3F4F6)
                          : const Color(0xFF111418),
                ),
              ),
              if (running && p.total > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(value: p.fraction),
                ),
              ],
              const SizedBox(height: 4),
              _CountsLine(dark: dark, paused: paused, compact: false),
            ],
          ),
        );
      },
    );
  }
}

/// "N files indexed · folders: A, B" — answers "is everything indexed?"
/// without opening Settings. Reads committed rows, so it stays truthful
/// while a run is in progress.
class _CountsLine extends StatelessWidget {
  final bool dark;
  final bool paused;
  final bool compact;
  const _CountsLine({
    required this.dark,
    this.paused = false,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({int count, List<String> scopes})>(
      future: _counts(),
      builder: (context, snap) {
        final count = snap.data?.count;
        final scopes = snap.data?.scopes ?? const <String>[];
        final text = count == null
            ? 'Checking index…'
            : scopes.isEmpty
                ? '$count files indexed · no folders selected'
                : '$count files indexed · ${scopes.length} '
                    'folder${scopes.length == 1 ? '' : 's'}: '
                    '${scopes.take(3).join(', ')}'
                    '${scopes.length > 3 ? ' +${scopes.length - 3} more' : ''}';
        final widget = Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: paused
                ? const Color(0xFF92400E)
                : dark
                    ? const Color(0xFF9CA3AF)
                    : const Color(0xFF6B7280),
          ),
        );
        if (!compact) return widget;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: dark ? QueryPicColors.surfaceDark : Colors.white,
            border: Border.all(
              color: dark
                  ? QueryPicColors.borderDark
                  : const Color(0xFFE2E8F0),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Text('✅ ', style: TextStyle(fontSize: 12)),
              Expanded(child: widget),
            ],
          ),
        );
      },
    );
  }

  Future<({int count, List<String> scopes})> _counts() async {
    try {
      final app = await AppIndex.ensure();
      final count = await app.db.realFileCount();
      final scopes = await ScopeStore.getScopedUris();
      return (count: count, scopes: scopes);
    } catch (_) {
      return (count: 0, scopes: const <String>[]);
    }
  }
}
