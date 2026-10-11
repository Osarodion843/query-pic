import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Random install UUID for single-use license redemption (no hardware
/// identifiers, no personal data — just a random string that lets the
/// backend tell "same install re-activating" from "second device").
/// Stored in prefs; a reinstall generates a new one (documented: support
/// resets the key in that case — see server/README.md).
class DeviceStore {
  static const keyDeviceId = 'querypic_device_id';

  static Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(keyDeviceId);
    if (id == null || id.isEmpty) {
      id = _newId();
      await prefs.setString(keyDeviceId, id);
    }
    return id;
  }

  static String _newId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
