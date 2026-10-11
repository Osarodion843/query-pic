"""Phase 7 contract checks (host-runnable, static).

Verifies the monetization code without store accounts:
  1. Counter: real-file accounting, worker hard-stop at 10k for Free
  2. Triggers: 80% cap banner with upgrade CTA, paywall on Pro attempts
  3. Purchases: Paystack live checkout, single-use serverless fulfillment
     (webhook -> key -> email -> one-time redeem), license-key
     entitlement with offline grace, debug Pro switch
  4. Analytics: count-only wrapper, opt-in gated, local audit sink

Store/billing configuration (accounts, links, SKUs, receipt validation)
is a production step — see the human-steps list.

Usage: python tools/phase7_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TESTS = os.path.join(ROOT, "querypic", "test")


def read_dart(*parts: str) -> str:
    with open(os.path.join(LIB, *parts), encoding="utf-8") as f:
        return f.read()


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}"
              + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    worker = read_dart("services", "index_worker.dart")
    check("cap: worker hard-stop at 10k for Free",
          "pausedCap" in worker and "freeCap" in worker and
          "realFileCount" in worker)
    check("cap: Pro bypasses", "gate!.isPro" in worker)
    check("cap: 80% banner with upgrade CTA",
          "10,000" in read_dart("screens", "home_search_screen.dart") and
          "Upgrade" in read_dart("screens", "home_search_screen.dart"))
    check("cap: paywall CTA on banner",
          "showPaywallSheet" in
          read_dart("screens", "home_search_screen.dart"))
    check("accounting: synthetic scopes excluded from cap",
          "demo://%" in read_dart("services", "index_database.dart"))
    lic = read_dart("services", "license_store.dart")
    check("license: format validation", "QP-PRO-" in lic)
    check("license: offline grace window", "graceDays" in lic)
    check("license: settings entry point", "Enter license key" in
          read_dart("screens", "settings_screen.dart"))
    check("license: single-use redeem API", "redeem(" in lic and
          "/api/redeem" in lic)
    check("license: backend base URL configurable",
          "licenseApiBase" in read_dart("services", "backend_keys.dart"))
    check("license: device install id (no hardware IDs)",
          "device_store.dart" in " ".join(os.listdir(
              os.path.join(ROOT, "querypic", "lib", "services"))))
    for name in ["paystack-webhook.js", "redeem.js", "keys.js",
                 "package.json", "vercel.json", ".env.example",
                 "README.md"]:
        check(f"server: {name} present",
              os.path.isfile(os.path.join(ROOT, "server",
                                          "api" if name.endswith(".js") and
                                          name != "keys.js" else
                                          "lib" if name == "keys.js" else "",
                                          name)))
    bill = read_dart("services", "billing_links.dart")
    check("billing: Stripe placeholders, never dead links",
          "customerPortalUrl" in bill and
          "production step" in bill.lower())
    check("billing: provider selects Stripe vs Paystack",
          "BillingProvider" in bill and "paystack" in bill.lower())
    check("billing: Paystack page URLs + support fallback",
          "paystackMonthlyUrl" in bill and "supportLine" in bill)
    check("billing: live checkout vs debug stub split",
          "checkoutMonthly" in
          read_dart("screens", "paywall_sheet.dart"))
    check("billing: portal guarded when unconfigured",
          "isConfigured" in read_dart("screens", "settings_screen.dart"))
    check("billing: no-portal path explains support route",
          "supportLine" in read_dart("screens", "settings_screen.dart"))
    ana = read_dart("services", "analytics.dart")
    check("analytics: count-only wrapper", "event(" in ana)
    check("analytics: opt-in gated", "isTelemetryOptIn" in ana)
    check("analytics: local audit sink", "recorder" in ana)
    check("analytics: paywall views/conversions tracked",
          "paywall_viewed" in read_dart("screens", "paywall_sheet.dart") and
          "subscribed" in read_dart("screens", "paywall_sheet.dart"))
    bt = open(os.path.join(TESTS, "billing_test.dart"),
              encoding="utf-8").read()
    check("test: license format matrix", "validateFormat" in bt)
    check("test: provider wiring live URLs configured",
          "BillingLinks provider wiring" in bt and
          "paystack.shop" in bt)

    print()
    if failures:
        print(f"FAIL: {len(failures)} failures")
        return 1
    print("PASS: 0 failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
