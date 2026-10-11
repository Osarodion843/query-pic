import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/account_store.dart';

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
}
