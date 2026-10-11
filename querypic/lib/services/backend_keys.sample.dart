/// Production backend keys (Step 7) — SAMPLE. Copy to backend_keys.dart
/// and paste real values (that file is git-ignored; never commit keys).
///
/// - Aptabase App Key: `A-REGION-XXXXXXXXXX` from aptabase.com → New App.
/// - GlitchTip DSN: `https://xxx@host/y` from your GlitchTip project.
///   (Sentry-compatible envelope endpoint; scrubbed payload only.)
/// - License API base: your `server/` deployment URL
///   (e.g. `https://querypic-license.vercel.app`) — enables single-use
///   key redemption. Empty = dev-only offline accept (debug builds).
class BackendKeys {
  static const aptabaseAppKey = '';
  static const glitchTipDsn = '';
  static const licenseApiBase = '';
}
