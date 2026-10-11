"""Phase 0 model/DB harness (host-runnable, stdlib-only).

Does NOT load real CLIP/Whisper models (they cannot be fetched on this host).
Instead it proves the surrounding contract Phase 2-3 will rely on:
  1. Sandbox layout exists: models/ db/ thumbs/ queue/
  2. schema_v1.sql applies cleanly to sandbox db
  3. Synthetic INT8-vector insert + brute-force top-K latency is measured
     and index size per 10k files is projected
  4. Peak Python RAM during the run is reported (tracemalloc)

Usage: python tools/model_harness.py [--rows 2000] [--dim 128]
Exit 0 on PASS, 1 on FAIL.
"""
import argparse
import os
import random
import sqlite3
import sys
import time
import tracemalloc

from text_index import assert_no_fts5, insert_tokens, token_search

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SANDBOX = os.path.join(ROOT, "querypic", "sandbox")
DB_PATH = os.path.join(SANDBOX, "db", "index.db")
SCHEMA = os.path.join(ROOT, "tools", "schema_v1.sql")


def check_layout() -> list[str]:
    errors = []
    for sub in ("models", "db", "thumbs", "queue"):
        p = os.path.join(SANDBOX, sub)
        if not os.path.isdir(p):
            errors.append(f"missing sandbox dir: {p}")
    if not os.path.isfile(SCHEMA):
        errors.append(f"missing schema: {SCHEMA}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=2000)
    ap.add_argument("--dim", type=int, default=128)
    args = ap.parse_args()

    errors = check_layout()
    if errors:
        print("FAIL layout:")
        for e in errors:
            print(f"  - {e}")
        return 1

    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    tracemalloc.start()
    t0 = time.perf_counter()

    con = sqlite3.connect(DB_PATH)
    with open(SCHEMA, encoding="utf-8") as f:
        schema_sql = f.read()
    assert_no_fts5(schema_sql)
    con.executescript(schema_sql)

    rnd = random.Random(42)
    dim, rows = args.dim, args.rows
    t_ins = time.perf_counter()
    with con:
        for i in range(rows):
            uri = f"file:///scoped/DCIM/img_{i:05d}.jpg"
            cur = con.execute(
                "INSERT INTO files(uri,type,mtime,width,height,hash)"
                " VALUES(?,?,?,?,?,?)",
                (uri, "photo", 1700000000 + i, 4000, 3000, f"hash{i:05d}"),
            )
            fid = cur.lastrowid
            vec = bytes(rnd.randrange(256) for _ in range(dim))
            con.execute(
                "INSERT INTO embeddings(file_id,vec_int8,model_ver)"
                " VALUES(?,?,?)",
                (fid, vec, "fake-int8-v0"),
            )
            con.execute(
                "INSERT INTO ocr(file_id,text) VALUES(?,?)",
                (fid, f"receipt home depot {i}"),
            )
            insert_tokens(con, "ocr", fid, f"receipt home depot {i}")
    ins_ms = (time.perf_counter() - t_ins) * 1000

    # Brute-force top-K over INT8 bytes (pure python): latency proxy only.
    q = bytes(rnd.randrange(256) for _ in range(dim))
    t_q = time.perf_counter()
    cur = con.execute("SELECT file_id, vec_int8 FROM embeddings")
    scored = []
    for fid, blob in cur:
        s = sum(
            (a - 128) * (b - 128) for a, b in zip(q, blob)
        )
        scored.append((s, fid))
    scored.sort(reverse=True)
    topk_ms = (time.perf_counter() - t_q) * 1000
    top5 = [fid for _, fid in scored[:5]]

    # OCR token-index latency (replaces FTS5 — not on all OEM SQLite).
    # Every synthetic doc contains all three tokens, so recall must be full.
    t_f = time.perf_counter()
    found = token_search(con, "ocr", "receipt home depot", limit=rows)
    fts_ms = (time.perf_counter() - t_f) * 1000
    hits = len(found)
    con.close()

    size_kb = os.path.getsize(DB_PATH) / 1024
    proj_per_10k_mb = size_kb / rows * 10000 / 1024
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    total_ms = (time.perf_counter() - t0) * 1000

    print(f"rows={rows} dim={dim} db={size_kb:.1f}KB")
    print(f"insert_total={ins_ms:.1f}ms ({ins_ms/rows:.2f}ms/row, host-only, no ML)")
    print(f"bruteforce_topK_all_rows={topk_ms:.1f}ms top5={top5}")
    print(f"token_receipt_hits={hits} in {fts_ms:.2f}ms")
    print(f"projected_index_per_10k={proj_per_10k_mb:.1f}MB (target <=25MB)")
    print(f"peak_python_ram={peak/1024:.1f}KB total_harness={total_ms:.1f}ms")

    ok = True
    if proj_per_10k_mb > 25:
        print("FAIL: projected index exceeds 25MB/10k budget")
        ok = False
    if hits != rows:
        print("FAIL: token lookup mismatch")
        ok = False
    if fts_ms > 100:
        print("WARN: token lookup over budget on host (target <100ms on device)")
    if topk_ms > 500:
        print("WARN: brute-force scan over 500ms — device build needs IVF/HNSW (Phase 3)")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
