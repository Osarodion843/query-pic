"""Phase 1 contract checks (host-runnable, static).

Verifies the five Phase 1 tasks + exit criteria without a Flutter SDK:
  1. Welcome screen copy ("100% On-Device" + folder-choice mention)
  2. Consent defaults OFF (no pre-ticked opt-in; `?? false` fallback present)
  3. Permission/scope flow exists (ScopeStore add/remove/list + folder picker UI)
  4. Folder scope editable post-onboarding (Settings entry + firstRun flag)
  5. Home search skeleton (SearchBar + 3 static chips -> WorkspaceScreen)
  6. Theme tokens match DESIGN_SYSTEM.md v0.2 hex codes
  7. No network imports in new Dart files (air-gap holds)

Usage: python tools/phase1_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")

EXPECTED_TOKENS = {
    "0xFF6366F1": "primary light",
    "0xFFA5B4FC": "primary dark",
    "0xFF06B6D4": "accent light",
    "0xFF22D3EE": "accent dark",
    "0xFFF8FAFC": "bg light",
    "0xFF0B0F17": "bg dark",
    "0xFF131924": "surface dark",
    "0xFFE2E8F0": "border light",
    "0xFF1E293B": "border dark",
    "0xFFEEF2FF": "chip tint",
}

NET_PATTERNS = [
    r"package:http/", r"package:dio/", r"\bHttpClient\b",
    r"\bimport\s+socket\b", r"\bWebSocket\b",
]


def read(rel: str) -> str:
    with open(os.path.join(LIB, rel), encoding="utf-8") as f:
        return f.read()


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}" + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    # Files exist
    for rel in ("screens/welcome_screen.dart", "screens/consent_screen.dart",
                "screens/folder_picker_screen.dart",
                "screens/home_search_screen.dart",
                "screens/workspace_screen.dart",
                "screens/settings_screen.dart",
                "services/consent_store.dart",
                "services/scope_store.dart",
                "widgets/privacy_badge.dart", "theme.dart", "main.dart"):
        check(f"exists {rel}", os.path.isfile(os.path.join(LIB, rel)))

    welcome = read("screens/welcome_screen.dart")
    check("welcome: on-device promise",
          "100% On-Device" in welcome or "100% on-device" in welcome)
    check("welcome: folder choice mentioned",
          "folder" in welcome.lower())

    consent = read("services/consent_store.dart")
    check("consent: default OFF fallback",
          "?? false" in consent,
          "ConsentStore must fall back to false when unset")
    consent_ui = read("screens/consent_screen.dart")
    check("consent: switch starts off",
          re.search(r"bool _optIn\s*=\s*false", consent_ui) is not None,
          "consent switch must initialise to false")

    scope = read("services/scope_store.dart")
    for api in ("getScopedUris", "setScopedUris", "addUri", "removeUri", "clearAll"):
        check(f"scope: ScopeStore.{api}", api in scope)
    picker = read("screens/folder_picker_screen.dart")
    check("picker: persists granted URIs", "setScopedUris" in picker)
    check("picker: reusable post-onboarding", "firstRun" in picker)
    settings = read("screens/settings_screen.dart")
    check("settings: rescope entry",
          "FolderPickerScreen" in settings)
    check("settings: telemetry toggle",
          "setTelemetryOptIn" in settings)

    home = read("screens/home_search_screen.dart")
    check("home: SearchBar present", "SearchBar" in home)
    for chip in ("Receipts", "Videos with Speech", "Recent Sunset"):
        check(f"home: chip '{chip}'", chip in home)
    check("home: navigates to workspace", "WorkspaceScreen" in home)

    theme = read("theme.dart")
    for token, label in EXPECTED_TOKENS.items():
        check(f"theme: {label} {token}", token in theme)

    for rel in ("screens/welcome_screen.dart", "screens/consent_screen.dart",
                "screens/folder_picker_screen.dart",
                "screens/home_search_screen.dart",
                "screens/settings_screen.dart",
                "services/consent_store.dart",
                "services/scope_store.dart"):
        src = read(rel)
        bad = [p for p in NET_PATTERNS if re.search(p, src)]
        check(f"airgap: {rel}", not bad, f"network pattern {bad}")

    print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failures")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
