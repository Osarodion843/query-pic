import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics.dart';
import '../services/billing_links.dart';
import '../services/pro_gate.dart';

/// Pro paywall bottom sheet (Phase 5, task 6; PRD Journey Phase 3B/3C).
///
/// Inline preview, never a dead end. Two modes:
/// - Debug (no checkout URLs configured): 1-tap instant subscribe stub.
/// - Live (provider URLs configured): monthly/yearly checkout buttons
///   opening the provider page; entitlement travels by license key
///   (no backend), so the sheet says exactly that.
/// Returns true when the user subscribed (debug stub only).
Future<bool> showPaywallSheet(
  BuildContext context, {
  required ProFeature feature,
  required ProGate gate,
  String? note,
}) async {
  Analytics.event('paywall_viewed');
  final subscribed = await showModalBottomSheet<bool>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${feature.title} is Pro',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(feature.blurb),
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note),
          ],
          const SizedBox(height: 16),
          if (!BillingLinks.isConfigured)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  await gate.subscribe();
                  Analytics.event('subscribed');
                  if (context.mounted) Navigator.of(context).pop(true);
                },
                icon: const Icon(Icons.workspace_premium),
                label: const Text('Subscribe (debug: instant)'),
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(BillingLinks.checkoutMonthly),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.workspace_premium),
                label: const Text('Subscribe Monthly'),
              ),
            ),
            if (BillingLinks.checkoutYearly.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => launchUrl(
                    Uri.parse(BillingLinks.checkoutYearly),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Yearly (save more)'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'After paying you will receive a license key by email — '
              'enter it in Settings to unlock Pro.',
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ),
        ],
      ),
    ),
  );
  return subscribed ?? false;
}
