import 'package:flutter/material.dart';
import '../theme.dart';

/// Cyan accent pill: "100% on-device · 0 bytes uploaded".
class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: QueryPicColors.badgeBgLight,
        border: Border.all(color: QueryPicColors.badgeBorderLight),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        '🔒 100% on-device · 0 bytes uploaded',
        style: TextStyle(
          color: QueryPicColors.badgeTextLight,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
