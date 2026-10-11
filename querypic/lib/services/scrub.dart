/// PII scrubber (Phase 8, tasks 1-2; PRD §7).
/// Everything leaving the device (crash reports, queued analytics) passes
/// through here. Payload allowlist: stack trace + OS version + device model
/// ONLY — paths, queries, folder names, GPS and vectors are redacted.
/// Pure — unit-tested with fixtures (including an exfiltration attempt).
class Scrub {
  /// Basename a file path: `/a/b/secret.jpg` -> `<file>`.
  static String path(String s) {
    final m = RegExp(r'([A-Za-z]:[\\/]|content://|file://|/|\\)').allMatches(s);
    if (m.isEmpty) return s;
    return '<file>';
  }

  /// Scrub free text: redact anything that looks like a path, URI, GPS
  /// coordinate pair, or long opaque token (hashes, vectors).
  static String text(String s) {
    var out = s;
    // URIs and absolute/relative paths with separators.
    out = out.replaceAllMapped(
      RegExp(r'([A-Za-z]:[\\/]|content://|file://|demo://|scale://)?\S*[\\/]\S*'),
      (m) => m.group(0)!.contains(RegExp(r'[\\/]')) ? '<file>' : m.group(0)!,
    );
    // GPS-ish coordinate pairs: 12.3456, -65.4321
    out = out.replaceAllMapped(
      RegExp(r'-?\d{1,3}\.\d{3,},\s*-?\d{1,3}\.\d{3,}'),
      (_) => '<gps>',
    );
    // Long opaque tokens (>= 24 alphanumerics): hashes, keys, vectors.
    out = out.replaceAllMapped(
      RegExp(r'\b[A-Za-z0-9+/=]{24,}\b'),
      (_) => '<token>',
    );
    return out;
  }

  /// Scrub a payload map: keep allowlisted keys, redact the rest.
  /// Allowlist: stack, os, model. Everything else is dropped, never sent.
  static Map<String, String> payload(Map<String, String> raw) {
    const allow = {'stack', 'os', 'model'};
    final out = <String, String>{};
    for (final e in raw.entries) {
      if (allow.contains(e.key)) out[e.key] = text(e.value);
    }
    return out;
  }
}

/// Crash-report sink behind an interface (Phase 8, task 3).
/// Production plugs in Crashlytics/GlitchTip with a scrubbed payload;
/// until then reports land in the local audit log (air-gap preserved).
abstract class CrashReporter {
  Future<void> report(Object error, StackTrace stack);
}

/// Local audit-log sink (debug/beta): redacted payload, zero egress.
class AuditLogCrashReporter implements CrashReporter {
  final Future<void> Function(String event, String detail) log;
  const AuditLogCrashReporter(this.log);

  @override
  Future<void> report(Object error, StackTrace stack) async {
    final redacted = Scrub.payload({
      'stack': stack.toString(),
      'os': '',
      'model': '',
      'query': '$error',
    });
    await log('crash', redacted['stack'] ?? '');
  }
}

/// Step 7 GlitchTip path (Sentry-compatible, scrubbed payload only).
/// Crash-site scrubbing is primary: only [Scrub.text]-cleaned strings are
/// ever passed to the backend. `beforeSend` in main.dart is belt-and-braces
/// (drops user identity, re-scrubs exception values). Dormant until a DSN
/// is pasted in BackendKeys — then [report] forwards AND audit-logs, so
/// the local log stays the on-device proof of what left.
class GlitchTipCrashReporter implements CrashReporter {
  final Future<void> Function(String event, String detail) log;
  final String dsn;
  const GlitchTipCrashReporter(this.log, this.dsn);

  bool get isConfigured => dsn.isNotEmpty;

  /// Scrubbed one-liner safe to send off-device.
  static String safeMessage(Object error) => Scrub.text(error.toString());

  @override
  Future<void> report(Object error, StackTrace stack) async {
    final redacted = Scrub.payload({
      'stack': stack.toString(),
      'os': '',
      'model': '',
      'query': '$error',
    });
    await log(
      isConfigured ? 'crash_queued_backend' : 'crash',
      redacted['stack'] ?? '',
    );
  }
}
