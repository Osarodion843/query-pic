"""Phase 3 contract checks (host-runnable, static + sqlite).

Verifies the five Phase 3 tasks without a device:
  1. Query path: tokenSearch + vectorScan + date filter + fuseAndRank wired
     in SearchService; TextEmbedder behind an interface (stub today)
  2. Date filters: keyword parsing (today/yesterday/week/month) + explicit
     range chips + filesInDateRange lookup
  3. UI: workspace grid + score badges + filter row + preview modal +
     empty/error states; no fake results without a backend
  4. Starter prompts: topTokens query + dynamic chips with static fallback
  5. Perf proxy: token lookup + brute-force vector scan over a 2k-row
     fixture must complete well under the 500ms query budget on host
     (device proof with real 20k library runs on hardware)

Exit-criterion proxies: <500ms query, <100ms OCR/date filter, airplane
parity (reuses airplane_smoke.py sources).

Usage: python tools/phase3_check.py [--rows 2000]
Exit 0 on PASS, 1 on FAIL.
"""
import argparse
import os
import random
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from text_index import insert_tokens, token_search, tokenize  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TOOLS = os.path.join(ROOT, "tools")


def read_dart(*parts: str) -> str:
    with open(os.path.join(LIB, *parts), encoding="utf-8") as f:
        return f.read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=2000)
    args = ap.parse_args()
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}"
              + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    for rel in ("services/query_engine.dart", "services/search_service.dart",
                "screens/workspace_screen.dart"):
        check(f"exists {rel}",
              os.path.isfile(os.path.join(LIB, rel)))
    check("exists test/search_test.dart",
          os.path.isfile(os.path.join(ROOT, "querypic", "test",
                                       "search_test.dart")))

    engine = read_dart("services", "query_engine.dart")
    check("fusion: 60/40 weights", "60 *" in engine and "40 *" in engine)
    check("fusion: score bands 80/50",
          "score >= 80" in engine and "score >= 50" in engine)
    check("fusion: unknown ids dropped", "if (file == null) continue" in engine)
    for kw in ("today", "yesterday", "last week", "last month"):
        check(f"dates: keyword '{kw}'", kw in engine.lower())
    check("dates: explicit range path", "filesInDateRange" in engine
          or "filesInDateRange" in read_dart("services", "index_database.dart"))
    check("dates: keywords stripped from tokens",
          "stripDateKeywords" in engine)

    svc = read_dart("services", "search_service.dart")
    check("service: embedder behind interface",
          "abstract class TextEmbedder" in svc
          and "StubTextEmbedder" in svc)
    check("service: reads committed rows only",
          "tokenSearch" in svc and "vectorScan" in svc
          and "filesByIds" in svc)
    check("service: date filter applied to all signals",
          svc.count("removeWhere") >= 2)

    db_src = read_dart("services", "index_database.dart")
    check("db: vectorScan cosine [-1,1]",
          "vectorScan" in db_src and "sqrt(qa)" in db_src)
    check("db: HNSW follow-up noted",
          "HNSW" in db_src or "IVF" in db_src)
    check("db: topTokens for starter chips", "topTokens" in db_src)

    ws = read_dart("screens", "workspace_screen.dart")
    check("ui: 3-col grid", "crossAxisCount: 3" in ws)
    check("ui: score badges with bands",
          "ScoreBand.high" in ws and "ScoreBand.mid" in ws)
    check("ui: bands never color-only (number renders)",
          re.search(r"\$\{result\.score\}%", ws) is not None)
    check("ui: date filter row",
          "Today" in ws and "Past week" in ws and "Past month" in ws)
    check("ui: preview modal", "showModalBottomSheet" in ws)
    check("ui: empty + error states",
          "No matches" in ws and "Search failed" in ws)
    check("ui: empty state guides somewhere real",
          "Seed demo library" in ws or "seed the demo" in ws or
          "Choose folders" in ws or "FolderPickerScreen" in ws)
    check("ui: app index fallback (no fake results)",
          "AppIndex" in ws)
    seed_src = open(os.path.join(LIB, "services", "debug_seed.dart"),
                    encoding="utf-8").read()
    check("seed: writes via real pipeline",
          "insertIndexed" in seed_src and "ocrText" in seed_src)
    check("seed: idempotent reseed",
          "deleteByScopePrefix" in seed_src)
    check("seed: dates spread for filter row",
          "daysAgo" in seed_src)
    check("seed: crawler fingerprint format",
          "$mtime|$size" in seed_src)
    check("seed: app-wide index backend",
          os.path.isfile(os.path.join(LIB, "services", "app_index.dart")))
    check("scale: 20k seeder with progress + idempotent reseed",
          "seedScale" in seed_src and "onProgress" in seed_src
          and "scaleScopePrefix" in seed_src)
    check("scale: timed queries with p95 report",
          "runScaleQueries" in seed_src and "p95" in seed_src)
    check("scale: synthetic cleanup keeps real rows",
          "clearSynthetic" in seed_src
          and "deleteByScopePrefix" in seed_src)
    with open(os.path.join(LIB, "screens", "settings_screen.dart"),
              encoding="utf-8") as f:
        settings_src = f.read()
    check("scale: settings entry points",
          "Seed 20k scale test" in settings_src
          and "Clear synthetic rows" in settings_src)
    check("ui: native handoff deferred honestly",
          "Phase 4" in ws)

    home = read_dart("screens", "home_search_screen.dart")
    check("chips: dynamic with static fallback",
          "dynamicChips" in home and "Receipts" in home)

    # Task 5 perf proxy on a synthetic fixture (tokenizer parity first).
    assert tokenize("Home Depot Receipt $84") == \
        ["84", "depot", "home", "receipt"], "tokenizer drift!"
    check("tokenizer: host contract stable", True)

    with open(os.path.join(TOOLS, "schema_v1.sql"), encoding="utf-8") as f:
        schema = f.read()
    con = sqlite3.connect(":memory:")
    con.executescript(schema)
    rnd = random.Random(11)
    words = ["receipt", "sunset", "dog", "birthday", "beach", "invoice",
             "mountain", "dinner", "scan", "park"]
    dim = 32
    for i in range(args.rows):
        text = " ".join(rnd.choice(words) for _ in range(4)) + f" doc{i}"
        cur = con.execute(
            "INSERT INTO files(uri,type,mtime,size,hash) VALUES(?,?,?,?,?)",
            (f"scope/img_{i}.jpg", "photo", 1700000000 + i, 2048,
             f"scope/img_{i}.jpg"),
        )
        fid = cur.lastrowid
        con.execute(
            "INSERT INTO embeddings(file_id,vec_int8,model_ver)"
            " VALUES(?,?,?)",
            (fid, bytes(rnd.randrange(256) for _ in range(dim)), "bench"),
        )
        con.execute("INSERT INTO ocr(file_id,text) VALUES(?,?)",
                    (fid, text))
        insert_tokens(con, "ocr", fid, text)

    # OCR/date filter proxy (<100ms budget).
    t0 = time.perf_counter()
    tok_rows = token_search(con, "ocr", "receipt sunset", limit=50)
    tok_ms = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    date_rows = con.execute(
        "SELECT id FROM files WHERE mtime >= ? AND mtime <= ?",
        (1700000000, 1700000000 + args.rows),
    ).fetchall()
    date_ms = (time.perf_counter() - t0) * 1000
    check("perf: token lookup <100ms", tok_ms < 100, f"{tok_ms:.1f}ms")
    check("perf: date lookup <100ms", date_ms < 100, f"{date_ms:.1f}ms")

    # Full query proxy: token + brute-force vector + fuse, end to end.
    q = bytes(rnd.randrange(256) for _ in range(dim))
    t0 = time.perf_counter()
    vec_rows = con.execute("SELECT file_id, vec_int8 FROM embeddings")
    import math
    scored = []
    for fid, blob in vec_rows:
        dot = sum((a - 128) * (b - 128) for a, b in zip(q, blob))
        qa = sum((a - 128) ** 2 for a in q)
        ba = sum((b - 128) ** 2 for b in blob)
        if qa and ba:
            scored.append((fid, dot / math.sqrt(qa * ba)))
    scored.sort(key=lambda e: -e[1])
    vec_top = dict(scored[:50])
    tok_map = {r[0]: r[1] for r in tok_rows}
    fused = sorted(set(tok_map) | set(vec_top),
                   key=lambda i: (-tok_map.get(i, 0),
                                  -vec_top.get(i, -1)))
    query_ms = (time.perf_counter() - t0) * 1000 + tok_ms
    check("perf: full query proxy <500ms on 2k rows",
          query_ms < 500, f"{query_ms:.1f}ms")
    check("perf: fusion returns ranked ids", len(fused) > 0)
    con.close()

    print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failures")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
