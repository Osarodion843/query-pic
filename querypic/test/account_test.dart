import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/account_backup.dart';
import 'package:querypic/services/account_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Account RBAC contracts (host-runnable, prefs-free): PIN hashing,
/// profile JSON round-trip, and the invariants the UI relies on.
void main() {
  group('AccountStore.hashPin', () {
    test('salted SHA-256 hex, deterministic, salt-sensitive', () {
      final a = AccountStore.hashPin('salt1', '1234');
      expect(a, AccountStore.hashPin('salt1', '1234'));
      expect(a.length, 64);
      expect(a, isNot(AccountStore.hashPin('salt2', '1234')));
      expect(a, isNot(AccountStore.hashPin('salt1', '1235')));
    });
  });

  group('AccountProfile', () {
    test('JSON round-trip preserves role', () {
      const p = AccountProfile(
        id: 'u1',
        name: 'Osas',
        isAdmin: true,
        createdMs: 1,
      );
      final back = AccountProfile.fromJson(p.toJson());
      expect(back?.id, 'u1');
      expect(back?.name, 'Osas');
      expect(back?.isAdmin, isTrue);
    });

    test('malformed JSON yields null, never throws', () {
      expect(AccountProfile.fromJson({}), isNull);
      expect(AccountProfile.fromJson({'id': '', 'name': 'x'}), isNull);
      expect(AccountProfile.fromJson({'id': 'u1'}), isNull);
    });
  });

  group('AccountStore trash', () {
    test('delete parks, restore returns with id intact', () async {
      SharedPreferences.setMockInitialValues({});
      final admin = await AccountStore.create(
        name: 'Admin',
        pin: '1234',
      );
      expect(admin.isAdmin, isTrue);
      final user = await AccountStore.create(name: 'Kid');
      expect(await AccountStore.delete(user.id), isTrue);
      expect(
        (await AccountStore.profiles()).map((p) => p.id),
        isNot(contains(user.id)),
      );
      final trashed = await AccountStore.trash();
      expect(trashed.map((t) => t.profile.id), contains(user.id));
      expect(await AccountStore.restore(user.id), isTrue);
      final back =
          (await AccountStore.profiles()).where((p) => p.id == user.id);
      expect(back.single.name, 'Kid');
    });

    test('last admin guard survives soft delete', () async {
      SharedPreferences.setMockInitialValues({});
      final admin = await AccountStore.create(
        name: 'Admin',
        pin: '1234',
      );
      await AccountStore.create(name: 'Kid');
      // Sole admin with others present: refuse (nothing trashed).
      expect(await AccountStore.delete(admin.id), isFalse);
      expect(await AccountStore.trash(), isEmpty);
    });
  });

  group('AccountBackup codec', () {
    test('export/import round-trips prefs minus device id', () async {
      SharedPreferences.setMockInitialValues({
        'querypic_device_id': 'do-not-export',
        'querypic_profiles': '[{"id":"u1","name":"A"}]',
        'plain_flag': true,
      });
      final bundle = await AccountBackup.exportBackup('s3cret');
      expect(bundle.fileName.endsWith('.qpbackup'), isTrue);
      expect(bundle.bytes.length, greaterThan(44));
      SharedPreferences.setMockInitialValues({});
      final result = await AccountBackup.importBackup(
        bundle.bytes,
        's3cret',
      );
      expect(result.profiles, 1);
      expect(result.keys, greaterThanOrEqualTo(2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('querypic_profiles'), contains('u1'));
      // Device id regenerates fresh (never cloned across phones).
      expect(prefs.getString('querypic_device_id'), isNull);
    });

    test('wrong password and garbage fail closed', () async {
      SharedPreferences.setMockInitialValues({});
      final bundle = await AccountBackup.exportBackup('right');
      expect(
        AccountBackup.importBackup(bundle.bytes, 'wrong'),
        throwsA(isA<FormatException>()),
      );
      expect(
        AccountBackup.importBackup(Uint8List(0), 'right'),
        throwsA(isA<FormatException>()),
      );
      expect(AccountBackup.exportBackup(''), throwsStateError);
    });
  });
}
