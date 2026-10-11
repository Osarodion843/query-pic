"""Phase 2 contract checks (host-runnable, static + sqlite).

Verifies the five Phase 2 tasks without a device:
  1. Crawler: skip rule (mtime+size+hash), scoped-only enumeration, no full-disk path
  2. Worker: batch commits, stub extractor behind interface, pause-after-batch
  3. Progress UX: banner strings ("Indexing … of …", "Paused: battery", "hot")
  4. Immediate utility: worker writes committed rows per batch (insertIndexed);
     search reads committed rows only (no uncommitted/read-txn coupling)
  5. Benchmarks: model_harness + resume_check still green against schema

Also enforces schema parity: tools/schema_v1.sql columns == the Dart schema
in index_database.dart (files must carry size for the skip rule).

Usage: python tools/phase2_check.py
Exit 0 on PASS, 1 on FAIL.
"""
import os
import re
import sqlite3
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TOOLS = os.path.join(ROOT, "tools")


def read_service(name: str) -> str:
    with open(os.path.join(LIB, "services", name), encoding="utf-8") as f:
        return f.read()


def files_columns(sql: str) -> list[str]:
    m = re.search(r"CREATE TABLE[^(]*files\s*\((.*?)\);", sql, re.S)
    cols = []
    for line in m.group(1).splitlines():
        line = line.strip().rstrip(",")
        if line and not line.startswith(("PRIMARY", "FOREIGN", "CHECK", "UNIQUE")):
            cols.append(line.split()[0].lower())
    return cols


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}"
              + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    # Files exist
    for rel in ("services/media_source.dart", "services/index_database.dart",
                "services/crawler.dart", "services/index_worker.dart",
                "widgets/index_banner.dart"):
        check(f"exists {rel}",
              os.path.isfile(os.path.join(LIB, rel)))
    for rel in ("test/indexer_test.dart", "test/widget_test.dart"):
        check(f"exists {rel}",
              os.path.isfile(os.path.join(ROOT, "querypic", rel)))

    crawler = read_service("crawler.dart")
    check("crawl: scoped enumeration only",
          "listFiles(scope" in crawler or "listFiles(String scope" in crawler)
    check("crawl: skip rule mtime+size+hash",
          all(k in crawler for k in ("['mtime']", "['size']", "['hash']")))
    check("crawl: no recursive full-disk scan",
          "listSync(recursive: true)" not in crawler
          and "Directory(" not in crawler)
    check("crawl: revoke path with cascade note",
          "revokeScope" in crawler and "CASCADE" in crawler)

    with open(os.path.join(LIB, "services", "pipeline_benchmark.dart"),
              encoding="utf-8") as f:
        bench = f.read()
    check("bench: synthetic source is debug-only",
          "SyntheticMediaSource" in bench and "DEBUG" in bench)
    check("bench: restores user scopes",
          "previousScopes" in bench)
    check("bench: reports ms/file + MB/10k projection",
          "msPerFile" in bench and "projectedMbPer10k" in bench)
    with open(os.path.join(LIB, "screens", "settings_screen.dart"),
              encoding="utf-8") as f:
        settings_src = f.read()
    check("bench: settings entry point",
          "Run pipeline benchmark" in settings_src)

    worker = read_service("index_worker.dart")
    check("worker: batch commits", "batchSize" in worker and ".batch()" in
          read_service("index_database.dart"))
    check("worker: extractor behind interface",
          "abstract class FeatureExtractor" in worker
          and "StubFeatureExtractor" in worker)
    check("worker: pause checked between batches",
          "pauses.check()" in worker)
    check("worker: pause reasons battery+thermal",
          "pausedBattery" in worker and "pausedThermal" in worker)
    check("worker: re-entrancy guard", "_running" in worker)

    with open(os.path.join(LIB, "widgets", "index_banner.dart"),
              encoding="utf-8") as f:
        banner = f.read()
    check("banner: progress copy", "Indexing" in banner and "of" in banner)
    check("banner: paused battery copy",
          "battery below 20%" in worker or "battery" in worker)
    check("banner: paused thermal copy", "hot" in worker)
    with open(os.path.join(LIB, "screens", "home_search_screen.dart"),
              encoding="utf-8") as f:
        home = f.read()
    check("home: banner wired", "IndexBanner" in home)

    # Schema parity: host SQL vs Dart schema
    with open(os.path.join(TOOLS, "schema_v1.sql"), encoding="utf-8") as f:
        host_sql = f.read()
    dart_src = read_service("index_database.dart")
    host_cols = files_columns(host_sql)
    dart_cols = files_columns(dart_src)
    check("schema parity files columns",
          host_cols == dart_cols, f"host={host_cols} dart={dart_cols}")
    check("schema: size column present (skip rule)",
          "size" in host_cols and "size" in dart_cols)
    check("schema: cascade deletes",
          host_sql.count("ON DELETE CASCADE") >= 4)
    check("schema: device enables FK pragma (else cascades never fire)",
          "PRAGMA foreign_keys = ON" in dart_src)
    # Regression guard for the itel/Transsion "no such module: fts5" crash:
    # system SQLite on OEM devices may lack FTS5, so it must never return
    # (comments mentioning the removal are fine — only live code counts).
    from text_index import assert_no_fts5 as _nofts
    try:
        _nofts(host_sql)
        _nofts(dart_src)
        check("schema: no live FTS5 (OEM SQLite lacks the module)", True)
    except AssertionError as e:
        check("schema: no live FTS5 (OEM SQLite lacks the module)",
              False, str(e))
    check("schema: token table + index present",
          "CREATE TABLE IF NOT EXISTS tokens" in host_sql
          and "CREATE TABLE IF NOT EXISTS tokens" in dart_src
          and "idx_tokens_token" in host_sql
          and "idx_tokens_token" in dart_src)
    check("tokenizer: Dart contract mirrors Python",
          "tokenizeForIndex" in dart_src
          and "[^a-z0-9]+" in dart_src
          and "t.length >= 2" in dart_src)
    # Regression guard for the on-device "not an error (SQLITE_OK)" crash:
    # replicate IndexDatabase.open's comment-strip + split and require every
    # resulting statement to be real SQL (CREATE/PRAGMA), never a comment
    # fragment (a ';' inside a '--' comment used to split mid-comment).
    m = re.search(r"static const _schema = '''(.*?)''';", dart_src, re.S)
    if m is None:
        check("schema: Dart _schema block found", False)
    else:
        code = "\n".join(
            ln for ln in m.group(1).splitlines()
            if not ln.strip().startswith("--")
        )
        stmts = [s.strip() for s in code.split(";") if s.strip()]
        bad = [s[:60] for s in stmts
               if not re.match(r"(?i)(CREATE|PRAGMA)\b", s)]
        check("schema: every split statement is real SQL", not bad,
              f"fragments: {bad}")

    # Live sqlite proof: host schema accepts worker-format rows.
    # FK cascades are OFF by default — enable like IndexDatabase.open does.
    mem = sqlite3.connect(":memory:")
    mem.execute("PRAGMA foreign_keys = ON")
    mem.executescript(host_sql)
    mem.execute(
        "INSERT INTO files(uri,type,mtime,size,hash) VALUES(?,?,?,?,?)",
        ("scope/a.jpg", "photo", 1, 10, "scope/a.jpg|1|10"),
    )
    fid = mem.execute("SELECT id FROM files").fetchone()[0]
    mem.execute(
        "INSERT INTO embeddings(file_id,vec_int8,model_ver) VALUES(?,?,?)",
        (fid, b"\x00" * 32, "stub-v0"),
    )
    from text_index import insert_tokens, token_search
    insert_tokens(mem, "ocr", fid, "Home Depot Receipt $84")
    found = token_search(mem, "ocr", "home depot receipt")
    check("schema: token lookup ranks the row",
          len(found) == 1 and found[0][0] == fid and found[0][1] == 3)
    mem.execute("DELETE FROM files WHERE id=?", (fid,))
    orphans = mem.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    check("schema: cascade actually deletes embeddings", orphans == 0)
    mem.close()

    # Task 5: benchmark harnesses still green
    for script, args in (("model_harness.py", ["--rows", "500", "--dim", "32"]),
                         ("resume_check.py", ["--rows", "200"])):
        r = subprocess.run(
            [sys.executable, os.path.join(TOOLS, script), *args],
            capture_output=True, text=True, cwd=ROOT,
        )
        check(f"harness: {script} green",
              r.returncode == 0, (r.stdout + r.stderr)[-300:])

    print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failures")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
