/// Beta billing endpoints (Phase 7, task 3).
///
/// Two providers, one shape. Stripe is the production/US-entity path;
/// Paystack is the beta/NG path (free to start, pay-per-transaction).
/// Empty URLs = unconfigured: every call site explains instead of
/// opening dead links — never a crash, never a fake checkout.
enum BillingProvider { stripe, paystack }

class BillingLinks {
  static const provider = BillingProvider.paystack;

  // Stripe (production step: US entity + dashboard links).
  static const stripeMonthlyUrl = '';
  static const stripeYearlyUrl = '';
  static const customerPortalUrl = '';

  // Paystack (beta path): Payment Page URLs from the paystack.com
  // dashboard (recurring pages: one monthly, one yearly). Verified
  // with test-mode transactions 2026-10-06 (NGN 3,000 + 2x30,000).
  static const paystackMonthlyUrl =
      'https://paystack.shop/pay/aksnoe4wef';
  static const paystackYearlyUrl =
      'https://paystack.shop/pay/25387upccs';

  /// Where subscription help goes when there is no self-serve portal
  /// (Paystack has none — cancellations run through support).
  /// Empty = fall back to "reply to your activation email".
  /// Step 12: production support address (matches PRIVACY_POLICY.md).
  static const supportContact = 'querypicsupport@gmail.com';

  /// Monthly checkout for the active provider ('' when unconfigured).
  static String get checkoutMonthly {
    switch (provider) {
      case BillingProvider.stripe:
        return stripeMonthlyUrl;
      case BillingProvider.paystack:
        return paystackMonthlyUrl;
    }
  }

  /// Yearly checkout for the active provider ('' when unconfigured).
  static String get checkoutYearly {
    switch (provider) {
      case BillingProvider.stripe:
        return stripeYearlyUrl;
      case BillingProvider.paystack:
        return paystackYearlyUrl;
    }
  }

  /// Self-serve portal exists only on Stripe (production step).
  static bool get hasPortal =>
      provider == BillingProvider.stripe &&
      customerPortalUrl.isNotEmpty;

  static String get portalUrl => customerPortalUrl;

  /// Live checkout available (else the UI stays on the debug stub).
  static bool get isConfigured => checkoutMonthly.isNotEmpty;

  /// Human support path for manage/cancel without a portal.
  static String get supportLine => supportContact.isNotEmpty
      ? 'Contact $supportContact to manage or cancel.'
      : 'Reply to your activation email to manage or cancel.';
}
