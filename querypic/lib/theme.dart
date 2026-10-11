import 'package:flutter/material.dart';

/// Electric Violet & Cyber Cyan tokens — single source of truth.
/// Mirrors DESIGN_SYSTEM.md v0.2. Verify with tools/phase1_check.py.
abstract final class QueryPicColors {
  static const primaryLight = Color(0xFF6366F1);
  static const primaryDark = Color(0xFFA5B4FC);
  static const accentLight = Color(0xFF06B6D4);
  static const accentDark = Color(0xFF22D3EE);
  static const bgLight = Color(0xFFF8FAFC);
  static const bgDark = Color(0xFF0B0F17);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surfaceDark = Color(0xFF131924);
  static const borderLight = Color(0xFFE2E8F0);
  static const borderDark = Color(0xFF1E293B);
  static const chipTintLight = Color(0xFFEEF2FF);
  static const badgeBgLight = Color(0xFFE0F7FD);
  static const badgeBorderLight = Color(0xFFA5F3FC);
  static const badgeTextLight = Color(0xFF0E7490);
}

ThemeData buildLightTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: QueryPicColors.primaryLight,
    ).copyWith(
      primary: QueryPicColors.primaryLight,
      secondary: QueryPicColors.accentLight,
      surface: QueryPicColors.surfaceLight,
    ),
    scaffoldBackgroundColor: QueryPicColors.bgLight,
  );
}

ThemeData buildDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: QueryPicColors.primaryDark,
      secondary: QueryPicColors.accentDark,
      surface: QueryPicColors.surfaceDark,
    ),
    scaffoldBackgroundColor: QueryPicColors.bgDark,
  );
}
