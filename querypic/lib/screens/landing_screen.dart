import 'package:flutter/material.dart';

import '../theme.dart';
import 'account_setup_screen.dart';
import 'backup_restore.dart';
import 'welcome_screen.dart';

/// Marketing landing page: the first thing a fresh install shows.
/// Showcases what QueryPic does; every feature CTA routes to account
/// creation — nothing is usable without an account.
class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      QueryPicColors.primaryLight,
                      QueryPicColors.accentLight,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.image_search,
                  size: 44,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Find any photo or video\nwith words.',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Describe it like you remember it — QueryPic finds it '
                'on your phone. Nothing ever leaves the device.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: dark
                          ? const Color(0xFF9CA3AF)
                          : const Color(0xFF6B7280),
                    ),
              ),
              const SizedBox(height: 20),
              const _FeatureRow(
                icon: Icons.search,
                title: 'Search in your own words',
                body: '"Beach sunset from last summer" — '
                    'photos and videos, instantly.',
              ),
              const _FeatureRow(
                icon: Icons.mic,
                title: 'Ask out loud',
                body: 'Push-to-talk voice search, transcribed on-device.',
              ),
              const _FeatureRow(
                icon: Icons.text_fields,
                title: 'Words inside pictures',
                body: 'Receipts, posters, memes — text in images is searchable.',
              ),
              const _FeatureRow(
                icon: Icons.videocam,
                title: 'Spoken words in videos',
                body: 'Pro transcribes video speech with timestamps. '
                    'Requires a Pro subscription.',
              ),
              const _FeatureRow(
                icon: Icons.lock_outline,
                title: '100% on-device',
                body: 'No accounts on a server, no uploads, no tracking. '
                    'Your library never leaves this phone.',
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF1E293B)
                      : QueryPicColors.chipTintLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Free forever for up to 10,000 files. Pro unlocks '
                  'unlimited indexing, video speech search and smart '
                  'dates — one subscription, per account.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AccountSetupScreen(firstRun: true),
                  ),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text(
                  'Get started',
                  style: TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(height: 4),
              // Fresh installs and post-reset restarts land here with no
              // accounts: restoring a backup replaces creating one, and
              // continues into onboarding (consent + folders still apply,
              // since a wipe clears those too).
              TextButton(
                onPressed: () async {
                  if (await runBackupRestore(context) && context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => const WelcomeScreen(),
                      ),
                      (_) => false,
                    );
                  }
                },
                child: const Text('Restore from backup instead'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: QueryPicColors.primaryLight.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: QueryPicColors.primaryLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
