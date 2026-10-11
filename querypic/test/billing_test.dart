import 'package:flutter_test/flutter_test.dart';
import 'package:querypic/services/billing_links.dart';
import 'package:querypic/services/license_store.dart';

/// Pure-logic tests for the Phase 7 beta license format (host-runnable).
/// Signature verification against store servers is a production step.
void main() {
  group('LicenseStore.validateFormat', () {
    test('accepts well-formed beta keys', () {
      expect(LicenseStore.validateFormat('QP-PRO-AB12-CD34'), isTrue);
      expect(LicenseStore.validateFormat('qp-pro-ab12-cd34'), isTrue);
      expect(LicenseStore.validateFormat('  QP-PRO-AB12-CD34  '), isTrue);
    });

    test('rejects malformed keys', () {
      expect(LicenseStore.validateFormat(''), isFalse);
      expect(LicenseStore.validateFormat('QP-PRO-ABC-DEF'), isFalse);
      expect(LicenseStore.validateFormat('FREE-KEY-1234'), isFalse);
      expect(LicenseStore.validateFormat('QP-PRO-AB12'), isFalse);
    });
  });

  group('BillingLinks provider wiring', () {
    test('live paystack URLs are configured, no dead links', () {
      expect(BillingLinks.provider, BillingProvider.paystack);
      expect(BillingLinks.isConfigured, isTrue);
      expect(
        BillingLinks.checkoutMonthly,
        'https://paystack.shop/pay/aksnoe4wef',
      );
      expect(
        BillingLinks.checkoutYearly,
        'https://paystack.shop/pay/25387upccs',
      );
      for (final url in [
        BillingLinks.checkoutMonthly,
        BillingLinks.checkoutYearly,
      ]) {
        expect(url.startsWith('https://'), isTrue);
      }
      // No self-serve portal on Paystack: support route instead.
      expect(BillingLinks.hasPortal, isFalse);
    });

    test('support line routes to the Step 12 support address', () {
      expect(BillingLinks.supportContact, isNotEmpty);
      expect(
        BillingLinks.supportLine,
        contains(BillingLinks.supportContact),
      );
    });
  });
}
