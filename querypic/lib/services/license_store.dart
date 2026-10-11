import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'account_store.dart';
import 'backend_keys.dart';
import 'device_store.dart';
import 'pro_gate.dart';

/// Beta license-key entitlement (Phase 7, task 3).
/// Production replaces validation with StoreKit 2 / Play Billing receipts;
/// the gate call sites stay the same. Offline-first: a validated key
/// persists locally with a 7-day grace window (no network needed).
class LicenseStore {
  static const keyLicense = 'querypic_license_key';
  static const keyLicenseTs = 'querypic_license_ts';
  static const graceDays = 7;

  /// Debug/beta format check only: `QP-PRO-XXXX-XXXX` (any alphanumerics).
  /// Real signature verification lands with production billing (Phase 7
  /// production step — needs store accounts + server).
  static bool validateFormat(String key) {
    return RegExp(r'^QP-PRO-[A-Z0-9]{4}-[A-Z0-9]{4}$')
        .hasMatch(key.trim().toUpperCase());
  }

  /// Single-use redemption against the license backend (server/README.md).
  /// Returns a short user-safe outcome; throws nothing. The backend binds
  /// the burn to device AND active profile (`usedBy = device::account`),
  /// so a key unlocked on one profile cannot ride on another — not even
  /// on the same phone. Afterwards Pro lives in local storage and works
  /// fully offline. Empty [baseUrl] (default from BackendKeys) = dev-only
  /// offline accept.
  static Future<({bool ok, String message})> redeem(
    String key, {
    String? baseUrl,
  }) async {
    final clean = key.trim().toUpperCase();
    if (!validateFormat(clean)) {
      return (ok: false, message: 'Expected format QP-PRO-XXXX-XXXX.');
    }
    final base = (baseUrl ?? BackendKeys.licenseApiBase).trim();
    if (base.isEmpty) {
      // Dev-only bypass: no backend configured (debug builds).
      return (ok: true, message: 'Accepted (offline dev mode).');
    }
    final deviceId = await DeviceStore.deviceId();
    String account = '';
    try {
      account = (await AccountStore.active())?.id ?? '';
    } catch (_) {}
    HttpClientResponse? response;
    String body = '';
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      final request = await client.postUrl(
        Uri.parse('$base/api/redeem'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        json.encode({
          'key': clean,
          'deviceId': deviceId,
          'account': account,
        }),
      );
      response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      body = await response.transform(utf8.decoder).join();
      client.close();
    } on TimeoutException {
      return (
        ok: false,
        message: 'Verification timed out — check connection and retry.',
      );
    } catch (_) {
      return (
        ok: false,
        message: 'Could not reach the verification server — '
            'check connection and retry.',
      );
    }
    final status = response.statusCode;
    if (status == 200) return (ok: true, message: 'Pro unlocked.');
    if (status == 404) {
      return (
        ok: false,
        message: 'Unknown key — check it letter by letter and retry.',
      );
    }
    if (status == 410 || body.contains('"used"')) {
      return (
        ok: false,
        message: 'This key is already used on another device. '
            'Contact support to re-issue after a reinstall.',
      );
    }
    return (
      ok: false,
      message: 'Verification failed (code $status) — try again later.',
    );
  }

  static Future<String> _suffix() async {
    try {
      final active = await AccountStore.active();
      return active == null ? '' : '_${active.id}';
    } catch (_) {
      return '';
    }
  }

  static Future<void> save(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await ProTierStore.setPro(true);
    await prefs.setString(
      '$keyLicense${await _suffix()}',
      key.trim().toUpperCase(),
    );
    await prefs.setInt(
      '$keyLicenseTs${await _suffix()}',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<String?> readKey() async =>
      (await SharedPreferences.getInstance())
          .getString('$keyLicense${await _suffix()}');

  /// Offline grace: a saved key stays valid for [graceDays] without any
  /// network check. Production revalidates receipts server-side.
  static Future<bool> withinGrace() async {
    final prefs = await SharedPreferences.getInstance();
    final suffix = await _suffix();
    final ts = prefs.getInt('$keyLicenseTs$suffix');
    if (ts == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    return age < graceDays * 24 * 3600 * 1000;
  }
}
