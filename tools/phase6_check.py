"""Phase 6 contract checks (host-runnable, static).

Verifies the guardrail code without a device:
  1. Queue: per-file error capture (pass never aborts), crawler diff as
     the persistent retry queue, STT queue with charging/idle rule
  2. Guards: pure Guardrails.evaluate matrix, DevicePauseSignals wiring,
     vitals channel on both native shells, storage pause state + banner,
     RAM-pressure model unload
  3. Settings: index size display, rebuild, privacy audit row, transcribe
     row + auto toggle
  4. Audit: audit_log table in both schemas, self-healing writes

Device steps (monkey-test transitions, 5k soak, native channel runtime)
run on hardware.

Usage: python tools/phase6_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TESTS = os.path.join(ROOT, "querypic", "test")
ANDROID = os.path.join(
    ROOT, "querypic", "android", "app", "src", "main", "kotlin",
    "com", "example", "querypic", "MainActivity.kt")
IOS = os.path.join(ROOT, "querypic", "ios", "Runner", "AppDelegate.swift")


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
    check("queue: per-file errors captured, pass never aborts",
          "lastErrors" in worker and "catch (e)" in worker)
    check("queue: device pause signals wired",
          "DevicePauseSignals" in worker)
    check("queue: storage pause state + label",
          "pausedStorage" in worker and "1 GB" in worker)
    check("guards: pure Guardrails.evaluate",
          "GuardDecision" in read_dart("services", "guardrails.dart"))
    check("guards: STT charging/idle rule",
          "shouldTranscribeNow" in read_dart("services", "guardrails.dart"))
    check("guards: vitals channel with fallback",
          "querypic/vitals" in read_dart("services", "guardrails.dart") and
          "MissingPluginException" in read_dart("services", "guardrails.dart"))
    check("guards: RAM-pressure model unload",
          "MemoryPressureObserver" in read_dart("services", "guardrails.dart"))
    with open(ANDROID, encoding="utf-8") as f:
        kt = f.read()
    check("native: Android vitals channel",
          "querypic/vitals" in kt and "getVitals" in kt and
          "currentThermalStatus" in kt and "usableSpace" in kt)
    with open(IOS, encoding="utf-8") as f:
        sw = f.read()
    check("native: iOS vitals plugin",
          "querypic/vitals" in sw and "thermalState" in sw and
          "systemFreeSize" in sw)
    check("queue: STT derived pending queue",
          "pendingVideoIds" in read_dart("services", "stt_indexer.dart") and
          "TranscriptionQueue" in read_dart("services", "stt_indexer.dart"))
    db_src = read_dart("services", "index_database.dart")
    check("audit: audit_log table in Dart schema",
          "CREATE TABLE IF NOT EXISTS audit_log" in db_src)
    with open(os.path.join(ROOT, "tools", "schema_v1.sql"),
              encoding="utf-8") as f:
        sql = f.read()
    check("audit: audit_log table in host schema",
          "CREATE TABLE IF NOT EXISTS audit_log" in sql)
    check("audit: self-healing writes", "logAudit" in db_src)
    check("settings: index size row", "Index size" in
          read_dart("screens", "settings_screen.dart"))
    check("settings: rebuild index row", "Rebuild index" in
          read_dart("screens", "settings_screen.dart"))
    check("settings: privacy audit row", "Privacy audit" in
          read_dart("screens", "settings_screen.dart"))
    check("settings: transcribe + auto toggle",
          "Transcribe videos" in
          read_dart("screens", "settings_screen.dart") and
          "auto_transcribe_stt" in
          read_dart("screens", "settings_screen.dart"))
    check("banner: storage pause surfaced",
          "pausedStorage" in read_dart("widgets", "index_banner.dart"))
    check("main: memory-pressure observer registered",
          "MemoryPressureObserver()" in read_dart("main.dart"))
    it = open(os.path.join(TESTS, "indexer_test.dart"),
              encoding="utf-8").read()
    for name in ("Guardrails.evaluate", "low battery pauses",
                 "thermal serious pauses", "low disk stops",
                 "STT queue rule", "model cache unloads"):
        check(f"test: covers '{name}'", name in it)

    print()
    if failures:
        print(f"FAIL: {len(failures)} failures")
        return 1
    print("PASS: 0 failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
