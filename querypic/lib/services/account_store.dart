import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device accounts + roles (no server, no network — the air gap holds).
///
/// Two roles: Admin sees everything including every debug/developer row;
/// Normal users get the product surface only (library, search, voice,
/// Pro via Paystack + license key). Switching TO an admin profile
/// requires the admin PIN, so debug tools stay out of normal hands.
///
/// Honest scope: the PIN is a salted SHA-256 lock against casual access
/// on the device, not forensics-grade access control — there is no server
/// to rate-limit guesses. PIN + device lock screen is the threat model.
///
/// Pro/license storage is per account (see ProTierStore/LicenseStore
/// account keys): each profile unlocks Pro with its own key.
class AccountProfile {
  final String id;
  final String name;
  final bool isAdmin;
  final int createdMs;

  const AccountProfile({
    required this.id,
    required this.name,
    required this.isAdmin,
    required this.createdMs,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'isAdmin': isAdmin,
        'createdMs': createdMs,
      };

  static AccountProfile? fromJson(Map<String, Object?> json) {
    final id = json['id'] as String?;
    final name = json['name'] as String?;
    if (id == null || id.isEmpty || name == null) return null;
    return AccountProfile(
      id: id,
      name: name,
      isAdmin: (json['isAdmin'] as bool?) ?? false,
      createdMs: (json['createdMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class AccountStore {
  static const keyProfiles = 'querypic_profiles';
  static const keyActive = 'querypic_active_profile';
  static const keyPinSalt = 'querypic_pin_salt';
  static const keyPinHash = 'querypic_pin_hash';

  /// Pure: salted PIN hash (hex). Testable without prefs.
  static String hashPin(String salt, String pin) {
    final bytes = utf8.encode('$salt:$pin');
    return sha256.convert(bytes).toString();
  }

  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<List<AccountProfile>> profiles() async {
    final prefs = await _prefs;
    final raw = prefs.getString(keyProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      return [
        for (final e in list)
          if (e is Map<String, Object?>)
            ...[AccountProfile.fromJson(e)].whereType<AccountProfile>(),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveAll(List<AccountProfile> profiles) async {
    final prefs = await _prefs;
    await prefs.setString(
      keyProfiles,
      json.encode([for (final p in profiles) p.toJson()]),
    );
  }

  static Future<AccountProfile?> active() async {
    final prefs = await _prefs;
    final id = prefs.getString(keyActive);
    final all = await profiles();
    if (id == null) return all.isEmpty ? null : all.first;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return all.isEmpty ? null : all.first;
  }

  static Future<bool> get hasAccounts async =>
      (await profiles()).isNotEmpty;

  static Future<bool> get isActiveAdmin async =>
      (await active())?.isAdmin ?? false;

  /// Create a profile. The FIRST profile on a device is admin (sets the
  /// PIN); later ones are normal unless an admin explicitly grants it
  /// (pass isAdmin:true only from an admin-authorized flow).
  /// [allowFirstAdmin]=false forces normal even for the first profile
  /// (public user builds, where admins must never exist).
  static Future<AccountProfile> create({
    required String name,
    bool isAdmin = false,
    String? pin,
    bool allowFirstAdmin = true,
  }) async {
    final clean = name.trim().isEmpty ? 'User' : name.trim();
    final all = await profiles();
    final first = all.isEmpty;
    final profile = AccountProfile(
      id: 'u${DateTime.now().microsecondsSinceEpoch}',
      name: clean,
      isAdmin: (first && allowFirstAdmin) || isAdmin,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    all.add(profile);
    await _saveAll(all);
    final prefs = await _prefs;
    if (prefs.getString(keyActive) == null) {
      await prefs.setString(keyActive, profile.id);
    }
    // First profile sets the admin PIN (required); later admin grants
    // may rotate it by passing a new one.
    if ((first || isAdmin) && pin != null && pin.isNotEmpty) {
      await setPin(pin);
    }
    return profile;
  }

  /// Switch active profile. Targets that are admin require the PIN —
  /// otherwise any profile could self-promote by switching.
  /// Returns false when the PIN is wrong (no switch happens).
  static Future<bool> switchTo(String id, {String? pin}) async {
    final all = await profiles();
    AccountProfile? target;
    for (final p in all) {
      if (p.id == id) target = p;
    }
    if (target == null) return false;
    if (target.isAdmin && !(await verifyPin(pin ?? ''))) return false;
    final prefs = await _prefs;
    await prefs.setString(keyActive, id);
    return true;
  }

  static Future<bool> get hasPin async =>
      (await _prefs).getString(keyPinHash) != null;

  static Future<void> setPin(String pin) async {
    final prefs = await _prefs;
    var salt = prefs.getString(keyPinSalt);
    salt ??= DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    await prefs.setString(keyPinSalt, salt);
    await prefs.setString(keyPinHash, hashPin(salt, pin));
  }

  static Future<bool> verifyPin(String pin) async {
    final prefs = await _prefs;
    final salt = prefs.getString(keyPinSalt);
    final hash = prefs.getString(keyPinHash);
    if (salt == null || hash == null || pin.isEmpty) return false;
    return hashPin(salt, pin) == hash;
  }

  /// Preference key scoped to the active profile (per-account settings
  /// like auto-transcribe). No accounts yet (pre-onboarding) -> the
  /// legacy global key.
  static Future<String> scopedKey(String base) async {
    try {
      final active = await AccountStore.active();
      return active == null ? base : '${base}_${active.id}';
    } catch (_) {
      return base;
    }
  }

  /// Delete a profile (admin only — enforced by callers showing the UI).
  /// Refuses to delete the last admin while other profiles exist.
  /// Soft delete: the profile lands in trash for [trashDays] and can be
  /// restored with its id intact (so per-account Pro/license keys,
  /// which are keyed by profile id, keep working after restore).
  static const trashDays = 30;
  static const keyTrash = 'querypic_trash';

  static Future<List<({AccountProfile profile, int deletedMs})>>
      trash() async {
    final prefs = await _prefs;
    final raw = prefs.getString(keyTrash);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      final out = <({AccountProfile profile, int deletedMs})>[];
      for (final e in list) {
        if (e is! Map<String, Object?>) continue;
        final p = AccountProfile.fromJson(
          (e['profile'] as Map?)?.cast<String, Object?>() ?? {},
        );
        if (p == null) continue;
        out.add((
          profile: p,
          deletedMs: (e['deletedMs'] as num?)?.toInt() ?? 0,
        ),);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveTrash(
    List<({AccountProfile profile, int deletedMs})> trashed,
  ) async {
    final prefs = await _prefs;
    await prefs.setString(
      keyTrash,
      json.encode([
        for (final t in trashed)
          {'profile': t.profile.toJson(), 'deletedMs': t.deletedMs},
      ]),
    );
  }

  /// Drop trashed profiles older than [trashDays]. Runs on every trash
  /// read path (cheap) so the bin cannot grow forever.
  static Future<void> purgeTrash() async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - trashDays * 24 * 3600 * 1000;
    final kept =
        (await trash()).where((t) => t.deletedMs >= cutoff).toList();
    await _saveTrash(kept);
  }

  static Future<bool> delete(String id) async {
    final all = await profiles();
    final target =
        all.where((p) => p.id == id).toList();
    if (target.isEmpty) return false;
    final rest = all.where((p) => p.id != id).toList();
    if (target.first.isAdmin &&
        rest.isNotEmpty &&
        !rest.any((p) => p.isAdmin)) {
      return false;
    }
    // Soft delete: profile goes to trash (restorable 30d, id intact so
    // per-account Pro/license keys survive a restore). Purge expired
    // trash in the same pass.
    await purgeTrash();
    final trashed = await trash();
    trashed.add((
      profile: target.first,
      deletedMs: DateTime.now().millisecondsSinceEpoch,
    ),);
    await _saveTrash(trashed);
    await _saveAll(rest);
    final prefs = await _prefs;
    if (prefs.getString(keyActive) == id) {
      if (rest.isEmpty) {
        await prefs.remove(keyActive);
      } else {
        await prefs.setString(keyActive, rest.first.id);
      }
    }
    return true;
  }

  /// Restore a trashed profile by id. Anyone may restore (switching to an
  /// admin profile still demands the PIN), so a mistaken delete is never
  /// a lockout. Returns false when absent or expired.
  static Future<bool> restore(String id) async {
    await purgeTrash();
    final trashed = await trash();
    final hit = trashed.where((t) => t.profile.id == id).toList();
    if (hit.isEmpty) return false;
    final all = await profiles();
    if (all.any((p) => p.id == id)) {
      // Already back (double restore): drop the trash copy.
      await _saveTrash(trashed.where((t) => t.profile.id != id).toList());
      return true;
    }
    all.add(hit.first.profile);
    await _saveAll(all);
    await _saveTrash(trashed.where((t) => t.profile.id != id).toList());
    return true;
  }
}
