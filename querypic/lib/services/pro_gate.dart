import 'package:shared_preferences/shared_preferences.dart';

import 'account_store.dart';
import 'query_engine.dart';

/// Pro-gated capabilities (Phase 5, task 6; PRD §4 Pro tier).
enum ProFeature {
  timedFrames,
  seekToFrame,
  stt,
  transcript,
  fuzzyTemporal,
  visualSimilarity,
}

/// Human-facing copy for the paywall sheet (task 6 inline preview).
extension ProFeatureCopy on ProFeature {
  String get title {
    switch (this) {
      case ProFeature.timedFrames:
        return 'Timed frames';
      case ProFeature.seekToFrame:
        return 'Seek to matched moment';
      case ProFeature.stt:
        return 'Speech transcription';
      case ProFeature.transcript:
        return 'Transcript search';
      case ProFeature.fuzzyTemporal:
        return 'Smart dates';
      case ProFeature.visualSimilarity:
        return 'Find similar';
    }
  }

  String get blurb {
    switch (this) {
      case ProFeature.timedFrames:
        return 'Per-segment timestamps on every video, tappable in results.';
      case ProFeature.seekToFrame:
        return 'Open the native player right at the matched moment.';
      case ProFeature.stt:
        return 'On-device speech-to-text when charging and idle.';
      case ProFeature.transcript:
        return 'Spoken words become searchable with timestamps.';
      case ProFeature.fuzzyTemporal:
        return '"Last summer" and "recent" just work as date filters.';
      case ProFeature.visualSimilarity:
        return 'Start from one photo, find every lookalike.';
    }
  }
}

/// In-memory tier + capability check. AppIndex owns one instance shared by
/// search and UI, so a tier flip applies immediately; the flag persists via
/// [ProTierStore]. Free has no gated features by design — ungated behavior
/// (plain search, play-from-start) never consults the gate.
class ProGate {
  bool isPro;
  ProGate({this.isPro = false});

  bool canUse(ProFeature feature) => isPro;

  /// 1-tap subscribe (debug/stub): flips Pro locally and persists it.
  /// Production wires StoreKit 2 / Play Billing + Stripe Web Checkout
  /// (IMPLEMENTATION_PLAN Phase 7); the call sites stay the same.
  Future<void> subscribe() => setTier(true);

  Future<void> setTier(bool pro) async {
    isPro = pro;
    await ProTierStore.setPro(pro);
  }
}

/// Persisted tier flag (SharedPreferences, same pattern as consent_store).
/// Scoped per account: each profile unlocks Pro with its own license key.
/// Pre-account installs fall back to the legacy global key.
/// Pro is TIME-BOXED: monthly = 30d, yearly = 365d from server activation
/// (`validUntil` burn timestamp). The check is clock-based so the app
/// stays fully offline after activation (device-clock manipulation is the
/// accepted beta limitation, disclosed in code).
class ProTierStore {
  static const keyPro = 'querypic_is_pro';
  static const keyUntil = 'querypic_pro_until';
  static const fallbackDays = 30;

  static Future<String?> _accountSuffix() async {
    try {
      final active = await AccountStore.active();
      return active == null ? null : '_${active.id}';
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isPro() async {
    final prefs = await SharedPreferences.getInstance();
    final suffix = await _accountSuffix() ?? '';
    if (!(prefs.getBool('$keyPro$suffix') ?? false)) return false;
    var until = prefs.getInt('$keyUntil$suffix');
    if (until == null) {
      // Migration: pre-expiry installs (flag but no timestamp) get one
      // 30-day window from now, then fall under normal expiry.
      until = DateTime.now().millisecondsSinceEpoch +
          fallbackDays * 24 * 3600 * 1000;
      await prefs.setInt('$keyUntil$suffix', until);
    }
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// Expiry timestamp (ms) or null when not Pro. Powers "Pro until <date>".
  static Future<int?> expiryMs() async {
    final prefs = await SharedPreferences.getInstance();
    final suffix = await _accountSuffix() ?? '';
    if (!(prefs.getBool('$keyPro$suffix') ?? false)) return null;
    return prefs.getInt('$keyUntil$suffix');
  }

  /// Activate with a server-issued expiry. Missing/zero expiry (old
  /// servers, debug) falls back to a 30-day window, never forever.
  static Future<void> activate([int? validUntilMs]) async {
    final prefs = await SharedPreferences.getInstance();
    final suffix = await _accountSuffix() ?? '';
    final until = (validUntilMs != null && validUntilMs > 0)
        ? validUntilMs
        : DateTime.now().millisecondsSinceEpoch +
            fallbackDays * 24 * 3600 * 1000;
    await prefs.setBool('$keyPro$suffix', true);
    await prefs.setInt('$keyUntil$suffix', until);
  }

  static Future<void> setPro(bool value) async {
    if (value) {
      // Debug instant-subscribe: generous but still time-boxed (365d),
      // never permanent — expiry is a product rule, not a debug detail.
      await activate(
        DateTime.now().millisecondsSinceEpoch + 365 * 24 * 3600 * 1000,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final suffix = await _accountSuffix() ?? '';
    await prefs.setBool('$keyPro$suffix', false);
  }
}

/// Resolve the effective date filter for a parsed query under a tier.
/// Pure — unit-tested. Free + fuzzy-temporal runs unconstrained but reports
/// the preview flag so the UI can show the inline preview + paywall
/// (PRD Journey Phase 3B/3C: preview, never a dead end or a crash).
({DateFilter filter, ProFeature? preview}) resolveFilter({
  required DateFilter parsed,
  required bool isPro,
}) {
  if (parsed.fuzzy && !isPro) {
    return (filter: const DateFilter(), preview: ProFeature.fuzzyTemporal);
  }
  return (filter: parsed, preview: null);
}

/// Resolve a "Find similar" (visual similarity) request under a tier.
/// Pure — unit-tested. Free gets an empty result plus the preview feature;
/// Pro is allowed through.
({bool allowed, ProFeature? preview}) resolveSimilar({
  required bool isPro,
}) {
  if (isPro) return (allowed: true, preview: null);
  return (allowed: false, preview: ProFeature.visualSimilarity);
}
