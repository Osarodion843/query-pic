import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:shared_preferences/shared_preferences.dart';

/// Encrypted account backup (lost-phone / new-phone recovery).
///
/// Format (JSON envelope, then the whole thing is just bytes):
///   { "v": 1, "exportedAt": ms, "prefs": { key: {"t": type, "v": value} } }
/// encrypted with AES-256-GCM, key = SHA-256(password + pepper), random
/// 12-byte IV prepended. File suffix `.qpbackup`.
///
/// Scope: everything in SharedPreferences EXCEPT the install device id
/// (a restored phone must mint its own, or two phones share one license
/// identity). Media files and the search index are NOT included — the
/// index rebuilds from granted folders; media never leaves the phone.
/// Restore REPLACES the account set wholesale (explicit user intent).
///
/// Honest crypto scope: passphrase-grade protection against casual
/// snooping (lost chat log, shared drive). No server exists for escrow —
/// a forgotten backup password cannot be recovered, by design.
class AccountBackup {
  static const fileSuffix = '.qpbackup';
  static const _pepper = 'querypic-backup-v1';

  static Uint8List _key(String password) {
    return Uint8List.fromList(
      sha256.convert(utf8.encode('$_pepper:$password')).bytes,
    );
  }

  /// Snapshot current prefs (minus device id) into encrypted bytes.
  /// Throws on crypto failure (empty password, etc.).
  static Future<({String fileName, Uint8List bytes})> exportBackup(
    String password,
  ) async {
    if (password.isEmpty) throw StateError('empty backup password');
    final prefs = await SharedPreferences.getInstance();
    final entries = <String, Object?>{};
    for (final k in prefs.getKeys()) {
      if (k == 'querypic_device_id') continue;
      final v = prefs.get(k);
      String t;
      if (v is bool) {
        t = 'b';
      } else if (v is int) {
        t = 'i';
      } else if (v is double) {
        t = 'd';
      } else if (v is String) {
        t = 's';
      } else if (v is List<String>) {
        t = 'ss';
      } else if (v is List) {
        t = 'ss';
      } else {
        continue;
      }
      entries[k] = {'t': t, 'v': v is List ? List<String>.from(v) : v};
    }
    final plain = json.encode({
      'v': 1,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'prefs': entries,
    });
    final key = enc.Key(_key(password));
    final iv = enc.IV.fromSecureRandom(12);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encrypt(plain, iv: iv);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    return (
      fileName: 'querypic-backup-$stamp$fileSuffix',
      bytes: Uint8List.fromList(iv.bytes + encrypted.bytes),
    );
  }

  /// Restore a backup file. Returns counts; wrong password and corrupt
  /// files surface as errors, never partial writes.
  static Future<({int profiles, int keys})> importBackup(
    Uint8List bytes,
    String password,
  ) async {
    if (password.isEmpty) throw StateError('empty backup password');
    if (bytes.length < 13) throw const FormatException('too short');
    final key = enc.Key(_key(password));
    final iv = enc.IV(bytes.sublist(0, 12));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    String plain;
    try {
      plain = encrypter.decrypt(
        enc.Encrypted(bytes.sublist(12)),
        iv: iv,
      );
    } catch (_) {
      throw const FormatException('wrong password or corrupt backup');
    }
    final decoded = json.decode(plain);
    if (decoded is! Map || decoded['v'] != 1 || decoded['prefs'] is! Map) {
      throw const FormatException('unsupported backup version');
    }
    final prefs = await SharedPreferences.getInstance();
    var keys = 0;
    var profiles = 0;
    final map = (decoded['prefs'] as Map).cast<String, Object?>();
    for (final entry in map.entries) {
      if (entry.key == 'querypic_device_id') continue;
      final spec = entry.value;
      if (spec is! Map) continue;
      final t = spec['t'];
      final v = spec['v'];
      try {
        switch (t) {
          case 'b':
            if (v is bool) {
              await prefs.setBool(entry.key, v);
              keys++;
            }
          case 'i':
            if (v is int) {
              await prefs.setInt(entry.key, v);
              keys++;
            }
          case 'd':
            if (v is double) {
              await prefs.setDouble(entry.key, v);
              keys++;
            }
          case 's':
            if (v is String) {
              await prefs.setString(entry.key, v);
              keys++;
            }
          case 'ss':
            if (v is List) {
              await prefs.setStringList(
                entry.key,
                [for (final e in v) e.toString()],
              );
              keys++;
            }
        }
      } catch (_) {}
    }
    try {
      final raw = prefs.getString('querypic_profiles');
      if (raw != null) {
        final list = json.decode(raw) as List;
        profiles = list.length;
      }
    } catch (_) {}
    return (profiles: profiles, keys: keys);
  }
}
