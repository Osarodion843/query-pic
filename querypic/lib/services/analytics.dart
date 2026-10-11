import 'package:aptabase_flutter/aptabase_flutter.dart';

import 'backend_keys.dart';
import 'consent_store.dart';

/// Privacy-safe analytics (Phase 7, task 4 + Phase 8).
/// Counts only — event NAMES, never query content, paths, or vectors.
/// Requires telemetry opt-in; without a configured backend the event is
/// recorded to the local audit log instead (air-gap preserved).
/// Step 7 wiring: paste the key in [BackendKeys]; [initBackend] is called
/// once at startup from main.dart. Empty key = local-only, zero egress.
class Analytics {
  static String _appKey = '';
  static bool _backendReady = false;

  /// Local sink used while no backend is configured (audit log wiring in
  /// main.dart). Keeps the air-gap: events stay on device.
  static Future<void> Function(String event, String detail)? recorder;

  static bool get isConfigured => _appKey.isNotEmpty;

  static void configure(String appKey) {
    _appKey = appKey;
  }

  /// Call once at startup. No-op when no key is pasted (beta state).
  /// Never throws: a bad key just leaves the audit-log fallback in place.
  static Future<void> initBackend() async {
    const key = BackendKeys.aptabaseAppKey;
    if (key.isEmpty) return;
    try {
      configure(key);
      await Aptabase.init(key);
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
    }
  }

  /// Track a count-only event. Returns the sink used (for diagnostics):
  /// 'off' (opted out), 'audit' (local only), 'backend' (configured).
  static Future<String> event(String name) async {
    if (!await ConsentStore.isTelemetryOptIn()) return 'off';
    if (!isConfigured) {
      if (recorder != null) await recorder!('analytics_queued', name);
      return 'audit';
    }
    // Backend configured: counts only, never content. Fire-and-forget —
    // a backend failure falls back to the audit log, never a crash.
    // NOTE: 'sent' is logged only when the SDK was actually invoked;
    // an unready backend logs 'queued' so the audit trail never lies.
    if (_backendReady) {
      try {
        await Aptabase.instance.trackEvent(name);
      } catch (_) {
        if (recorder != null) await recorder!('analytics_queued', name);
        return 'audit';
      }
      if (recorder != null) await recorder!('analytics_sent', name);
      return 'backend';
    }
    if (recorder != null) await recorder!('analytics_queued', name);
    return 'audit';
  }
}
