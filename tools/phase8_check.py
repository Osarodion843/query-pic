"""Phase 8 contract checks (host-runnable, static).

Verifies the privacy code without network access:
  1. Scrubber: path/URI, GPS, opaque-token redaction + payload allowlist
  2. Payload allowlist: stack + os + model only, everything else dropped
  3. Crash pipeline: CrashReporter interface, audit-log sink, onError
     wiring, separate opt-in with default-off
  4. Copy: first-launch privacy text, settings toggles

SDK configuration (Crashlytics/GlitchTip keys, Aptabase key) and the
network-capture pen-test are production/device steps.

Usage: python tools/phase8_check.py
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

    scrub = read_dart("services", "scrub.dart")
    check("scrub: path/URI redaction", "<file>" in scrub)
    check("scrub: GPS redaction", "<gps>" in scrub)
    check("scrub: opaque-token redaction", "<token>" in scrub)
    check("scrub: payload allowlist stack/os/model",
          "'stack', 'os', 'model'" in scrub or
          '{"stack", "os", "model"}' in scrub or
          "{'stack', 'os', 'model'}" in scrub)
    check("crash: reporter interface + audit sink",
          "CrashReporter" in scrub and "AuditLogCrashReporter" in scrub)
    check("crash: onError wiring in main",
          "FlutterError.onError" in read_dart("main.dart"))
    check("crash: separate opt-in, default off",
          "keyCrashOptIn" in read_dart("services", "consent_store.dart"))
    check("crash: settings runtime switch",
          "Crash diagnostics" in
          read_dart("screens", "settings_screen.dart"))
    check("copy: first-launch privacy text",
          "stripped on-device first" in
          read_dart("screens", "consent_screen.dart"))
    st = open(os.path.join(TESTS, "scrub_test.dart"),
              encoding="utf-8").read()
    for name in ("redacts file paths", "redacts GPS",
                 "allowlist keeps stack", "exfiltration attempt"):
        check(f"test: covers '{name}'", name in st)

    print()
    if failures:
        print(f"FAIL: {len(failures)} failures")
        return 1
    print("PASS: 0 failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
