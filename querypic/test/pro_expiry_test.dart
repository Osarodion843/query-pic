import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/pro_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subscription expiry contracts (host-runnable, prefs-backed).
void main() {
  group('ProTierStore expiry', () {
    test('future expiry is Pro, past expiry is not', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await ProTierStore.isPro(), isFalse);
      final future =
          DateTime.now().millisecondsSinceEpoch + 30 * 24 * 3600 * 1000;
      await ProTierStore.activate(future);
      expect(await ProTierStore.isPro(), isTrue);
      expect(await ProTierStore.expiryMs(), future);
      final past = DateTime.now().millisecondsSinceEpoch - 1000;
      await ProTierStore.activate(past);
      expect(await ProTierStore.isPro(), isFalse);
      expect(await ProTierStore.expiryMs(), past);
    });

    test('legacy flag without timestamp migrates to 30 days, once', () async {
      SharedPreferences.setMockInitialValues({
        ProTierStore.keyPro: true,
      });
      expect(await ProTierStore.isPro(), isTrue);
      final first = await ProTierStore.expiryMs();
      expect(first, isNotNull);
      expect(
        first!,
        greaterThan(
          DateTime.now().millisecondsSinceEpoch + 29 * 24 * 3600 * 1000,
        ),
      );
      // Second read keeps the migrated value (no extension loop).
      expect(await ProTierStore.expiryMs(), first);
    });

    test('setPro(false) revokes immediately', () async {
      SharedPreferences.setMockInitialValues({});
      await ProTierStore.activate(
        DateTime.now().millisecondsSinceEpoch + 1000000,
      );
      expect(await ProTierStore.isPro(), isTrue);
      await ProTierStore.setPro(false);
      expect(await ProTierStore.isPro(), isFalse);
    });
  });
}
