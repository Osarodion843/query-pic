import 'package:shared_preferences/shared_preferences.dart';

/// Telemetry consent. DEFAULT OFF — only ever enabled by explicit user opt-in
/// on the ConsentScreen (PRD §7, Phase 1 exit criteria).
class ConsentStore {
  static const keyTelemetryOptIn = 'telemetry_opt_in';
  static const keyCrashOptIn = 'crash_opt_in';
  static const keyOnboardingDone = 'onboarding_done';

  /// Default is always false, even before anything is persisted.
  static Future<bool> isTelemetryOptIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyTelemetryOptIn) ?? false;
  }

  static Future<void> setTelemetryOptIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyTelemetryOptIn, value);
  }

  /// Crash-report opt-in (Phase 8, task 4): separate runtime switch so
  /// crash diagnostics can be toggled independently of analytics counts.
  static Future<bool> isCrashOptIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyCrashOptIn) ?? false;
  }

  static Future<void> setCrashOptIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyCrashOptIn, value);
  }

  static Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyOnboardingDone) ?? false;
  }

  static Future<void> setOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyOnboardingDone, true);
  }
}
