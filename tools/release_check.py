"""Phase 9 release gate (host-runnable orchestrator).

Runs every contract checker + harness and reports a single verdict:
  phase1..phase8 checks, resume_check (kill-restart), airplane_smoke
  (no-network static pass).

Device/production steps (matrix builds, store uploads, paid accounts,
network capture, monkey tests) run outside this script — see the
human-steps list.

Usage: python tools/release_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")

SUITE = [
    "phase1_check.py",
    "phase2_check.py",
    "phase3_check.py",
    "phase4_check.py",
    "phase5_check.py",
    "phase6_check.py",
    "phase7_check.py",
    "phase8_check.py",
    "resume_check.py",
    "airplane_smoke.py",
]


def main() -> int:
    failed: list[str] = []
    for script in SUITE:
        path = os.path.join(TOOLS, script)
        if not os.path.isfile(path):
            print(f"[SKIP] {script} (missing)")
            continue
        print(f"===== {script} =====")
        try:
            proc = subprocess.run(
                [sys.executable, path],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=600,
            )
        except subprocess.TimeoutExpired:
            print(f"[FAIL] {script} (timeout)")
            failed.append(script)
            continue
        tail = "\n".join(
            [ln for ln in proc.stdout.splitlines() if ln.startswith(
                ("PASS:", "FAIL:", "[FAIL]"))][-4:])
        print(tail)
        if proc.returncode != 0:
            failed.append(script)
    print()
    if failed:
        print(f"RELEASE GATE: FAIL ({', '.join(failed)})")
        return 1
    print("RELEASE GATE: PASS (host side; device/prod steps still human)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
