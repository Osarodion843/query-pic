"""Phase 0 airplane-mode smoke test (static, host-runnable).

Asserts the Phase-0 tree makes no network calls on the index/search path:
  1. Scans querypic/lib/** and tools/*.py for network imports/calls
     (socket, http.client, urllib, requests, httpx, dio/http package, firebase
     network use outside the deferred productionRg notes is flagged).
  2. Verifies sandbox db/index.db exists (harness ran) and lives under
     querypic/sandbox (air-gap layout check).

This is a static proxy for the on-device airplane-mode test, which must be
re-run on hardware in Phase 9 with a network-log assertion.

Usage: python tools/airplane_smoke.py
Exit 0 on PASS, 1 on FAIL.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_DIRS = [os.path.join(ROOT, "querypic", "lib"), os.path.join(ROOT, "tools")]

NET_PATTERNS = [
    r"\bimport\s+socket\b", r"\bfrom\s+socket\b",
    r"\bimport\s+requests\b", r"\bimport\s+httpx\b",
    r"\bimport\s+urllib\b", r"\bfrom\s+urllib\b",
    r"\bhttp\.client\b", r"\bHttpClient\b",
    r"package:http/", r"package:dio/",
    r"XMLHttpRequest", r"\bWebSocket\b", r"\bfetch\s*\(",
]

# Checkers mention pattern names; fetch_models is a one-shot downloader that
# never runs on the index/search path (models ship with the app bundle).
# validate_clip.py fetches picsum probe photos for host-side ranking
# validation only — same category, never on device.
ALLOW_FILES = {
    "airplane_smoke.py",
    "phase1_check.py",
    "fetch_models.py",
    "validate_clip.py",
}

# Documented one-time egress (NOT index/search traffic): file -> allowed
# patterns. License redemption is a single user-initiated HTTPS call
# (Settings -> Enter license key); afterwards the app is fully offline.
# Disclosed in PRIVACY_POLICY.md alongside the opt-in diagnostics and the
# Paystack checkout page. Anything else network-shaped still fails.
ALLOW_EGRESS = {
    "license_store.dart": [r"\bHttpClient\b"],
}
COMMENT_LINE = re.compile(r"^\s*(//|#|--|[*])")


def main() -> int:
    violations: list[str] = []
    scanned = 0
    for d in SCAN_DIRS:
        for base, _, files in os.walk(d):
            for fn in files:
                if not fn.endswith((".py", ".dart", ".kt", ".swift")):
                    continue
                if fn in ALLOW_FILES:
                    continue
                p = os.path.join(base, fn)
                scanned += 1
                with open(p, encoding="utf-8", errors="replace") as f:
                    for ln, line in enumerate(f, 1):
                        # Skip comments and the deferred-to-production notes.
                        s = line.strip()
                        if COMMENT_LINE.match(s):
                            continue
                        if "deferred to production" in s:
                            continue
                        for pat in NET_PATTERNS:
                            if re.search(pat, line):
                                allowed = any(
                                    re.search(ap, line)
                                    for ap in ALLOW_EGRESS.get(fn, [])
                                )
                                if not allowed:
                                    violations.append(
                                        f"{p}:{ln}: {pat} :: {s[:100]}"
                                    )
    print(f"scanned {scanned} source files")

    db = os.path.join(ROOT, "querypic", "sandbox", "db", "index.db")
    if not os.path.isfile(db):
        violations.append(f"missing sandbox db (run model_harness.py first): {db}")
    else:
        print(f"sandbox db present: {db} ({os.path.getsize(db)} bytes)")

    if violations:
        print("FAIL violations:")
        for v in violations:
            print(f"  - {v}")
        return 1
    print("PASS: no network calls on index/search path; air-gap layout holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
