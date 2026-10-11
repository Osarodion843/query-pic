import 'package:flutter/material.dart';
import '../services/app_index.dart';
import '../services/index_worker.dart';
import '../services/pro_gate.dart';
import '../theme.dart';
import '../widgets/index_banner.dart';
import '../widgets/privacy_badge.dart';
import 'paywall_sheet.dart';
import 'settings_screen.dart';
import 'voice_search_sheet.dart';
import 'workspace_screen.dart';

/// Quick-search home — search bar + static chips -> workspace.
/// Shows the indexing banner whenever a worker is attached (Phase 2, task 3).
/// Search reads committed rows only, so it stays usable while indexing runs.
class HomeSearchScreen extends StatelessWidget {
  final IndexWorker? worker;

  /// Dynamic starter chips from the indexed content distribution
  /// (Phase 3, task 4). Null until the index DB is wired in — the static
  /// fallback chips render meanwhile.
  final Future<List<String>> Function()? dynamicChips;
  const HomeSearchScreen({super.key, this.worker, this.dynamicChips});

  /// Fully-wired home: live worker (banner) + dynamic chips. Use this
  /// everywhere Home is pushed (onboarding gate, folder save) — a bare
  /// `const HomeSearchScreen()` shows no banner and static chips, which is
  /// exactly the "nothing happened until restart" bug.
  static HomeSearchScreen wired(IndexWorker worker) => HomeSearchScreen(
        worker: worker,
        dynamicChips: () async {
          final app = await AppIndex.ensure();
          final top = await app.db.topTokens('ocr');
          // Fall back to static chips on an empty index.
          return top.isEmpty
              ? const [
                  'Receipts',
                  'Videos with Speech',
                  'Recent Sunset',
                ]
              : top;
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QueryPic'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        // Landscape (and small screens): the headline + search + chips
        // overflow a fixed Column (BOTTOM OVERFLOWED). Scroll instead.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PrivacyBadge(),
              const _CapBannerSlot(),
              if (worker != null) ...[
                const SizedBox(height: 12),
                IndexBanner(
                  progress: worker!.progress,
                  initial: worker!.lastProgress,
                ),
              ],
              const SizedBox(height: 12),
              Text('Find any photo or video\nwith words.',
                  style: Theme.of(context).textTheme.headlineMedium,),
              const SizedBox(height: 12),
              // Search-as-you-type: suggestions complete the CURRENT word
              // from indexed vocabulary (teaches the library's words live).
              // Submit (or a suggestion tap) opens the workspace.
              SearchAnchor(
                builder: (context, controller) => SearchBar(
                  controller: controller,
                  hintText: 'Try "receipt from Home Depot"',
                  leading: const Icon(Icons.search),
                  trailing: [
                    IconButton(
                      icon: const Icon(Icons.mic),
                      tooltip: 'Voice search',
                      onPressed: () => showVoiceSearchSheet(context),
                    ),
                  ],
                  onTap: () => controller.openView(),
                  onChanged: (_) {
                    if (!controller.isOpen) controller.openView();
                  },
                ),
                viewHintText: 'Describe a photo or video',
                viewOnSubmitted: (q) => _open(context, q),
                suggestionsBuilder: (context, controller) async {
                  final words =
                      controller.text.split(RegExp(r'\s+'));
                  final last = words.isEmpty ? '' : words.last;
                  if (last.length < 2) return const <Widget>[];
                  List<String> completions = const [];
                  try {
                    final app = await AppIndex.ensure();
                    completions =
                        await app.db.completeTokens('ocr', last);
                  } catch (_) {}
                  return [
                    for (final w in completions)
                      ListTile(
                        leading: const Icon(Icons.north_west, size: 16),
                        title: Text(w),
                        onTap: () {
                          final q = [...words.sublist(0, words.length - 1), w]
                              .join(' ');
                          controller.closeView(q);
                          _open(context, q);
                        },
                      ),
                  ];
                },
              ),
              const SizedBox(height: 12),
              if (dynamicChips == null)
                Wrap(
                  spacing: 8,
                  children: [
                    _ActiveChip(
                        label: 'Receipts',
                        onTap: () => _open(context, 'Receipts'),),
                    _ActiveChip(
                        label: 'Videos with Speech',
                        onTap: () => _open(context, 'Videos with Speech'),),
                    _ActiveChip(
                        label: 'Recent Sunset',
                        onTap: () => _open(context, 'Recent Sunset'),),
                  ],
                )
              else
                FutureBuilder<List<String>>(
                  future: dynamicChips!(),
                  builder: (context, snapshot) {
                    final chips = snapshot.data;
                    if (chips == null || chips.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Wrap(
                      spacing: 8,
                      children: [
                        for (final c in chips.take(6))
                          _ActiveChip(
                            label: c,
                            onTap: () => _open(context, c),
                          ),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, String query) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WorkspaceScreen(query: query)),
    );
  }
}
class _ActiveChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ActiveChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Light tint bg + white default label is unreadable in dark mode
    // (white-on-pale). Pin explicit theme-aware colors per DESIGN_SYSTEM:
    // primary text on tint (light) / slate chip with lavender text (dark).
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ActionChip(
      label: Text(label),
      labelStyle: TextStyle(
        color: dark ? QueryPicColors.primaryDark : QueryPicColors.primaryLight,
        fontWeight: FontWeight.w600,
      ),
      onPressed: onTap,
      backgroundColor:
          dark ? const Color(0xFF1E293B) : QueryPicColors.chipTintLight,
      side: BorderSide(
        color: dark ? QueryPicColors.borderDark : QueryPicColors.borderLight,
      ),
    );
  }
}

/// Free-cap banner slot (Phase 7, tasks 1-2): amber at 80% of the 10k
/// Free cap with an upgrade CTA; hidden for Pro or small libraries.
class _CapBannerSlot extends StatelessWidget {
  const _CapBannerSlot();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: AppIndex.ensure(),
      builder: (context, snap) {
        final app = snap.data;
        if (app == null) return const SizedBox.shrink();
        return FutureBuilder<int>(
          future: app.db.realFileCount(),
          builder: (context, countSnap) {
            final count = countSnap.data ?? 0;
            if (app.search.gate.isPro || count < 8000) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Free library $count / 10,000 files.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => showPaywallSheet(
                        context,
                        feature: ProFeature.timedFrames,
                        gate: app.search.gate,
                        note: 'Pro unlocks unlimited indexing plus timed '
                            'frames, transcripts and smart dates.',
                      ),
                      child: const Text('Upgrade'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
