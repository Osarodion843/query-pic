"""Phase 2 kill-restart resume check (host-runnable).

Proves the exit criterion "kill + restart resumes without duplicates":
  1. Build a sandbox DB from schema_v1.sql with N synthetic files.
  2. Simulate a kill mid-pass: close the DB after committing only half.
  3. Re-run the crawler diff (mtime+size+hash skip rule, mirrored from
     Crawler.needsIndexing) and finish the pass.
  4. Assert total == N with zero duplicate URIs and all rows complete
     (files + embeddings + ocr + token coverage present for every file).

Usage: python tools/resume_check.py [--rows 500]
Exit 0 on PASS, 1 on FAIL.
"""
import argparse
import os
import random
import sqlite3
import sys

from text_index import insert_tokens

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(ROOT, "querypic", "sandbox", "db", "resume.db")
SCHEMA = os.path.join(ROOT, "tools", "schema_v1.sql")
DIM = 32


def fingerprint(uri: str, mtime: int, size: int) -> str:
    return f"{uri}|{mtime}|{size}"


def apply_schema(con: sqlite3.Connection) -> None:
    with open(SCHEMA, encoding="utf-8") as f:
        con.executescript(f.read())


def index_row(con: sqlite3.Connection, i: int, rnd: random.Random) -> None:
    uri = f"scope/DCIM/img_{i:05d}.jpg"
    mtime, size = 1700000000 + i, 2048 + (i % 7)
    vec = bytes(rnd.randrange(256) for _ in range(DIM))
    with con:
        cur = con.execute(
            "INSERT INTO files(uri,type,mtime,size,hash)"
            " VALUES(?,?,?,?,?)",
            (uri, "photo", mtime, size, fingerprint(uri, mtime, size)),
        )
        fid = cur.lastrowid
        con.execute(
            "INSERT INTO embeddings(file_id,vec_int8,model_ver)"
            " VALUES(?,?,?)",
            (fid, vec, "resume-check-v0"),
        )
        con.execute(
            "INSERT INTO ocr(file_id,text) VALUES(?,?)", (fid, f"doc {i}")
        )
        insert_tokens(con, "ocr", fid, f"doc {i}")


def needs_indexing(con: sqlite3.Connection, i: int) -> bool:
    """Mirror of Crawler.needsIndexing: skip iff mtime+size+hash all match."""
    uri = f"scope/DCIM/img_{i:05d}.jpg"
    mtime, size = 1700000000 + i, 2048 + (i % 7)
    row = con.execute(
        "SELECT mtime,size,hash FROM files WHERE uri=?", (uri,)
    ).fetchone()
    if row is None:
        return True
    return (
        row[0] != mtime
        or row[1] != size
        or row[2] != fingerprint(uri, mtime, size)
    )


def completeness(con: sqlite3.Connection) -> list[str]:
    problems = []
    n_files = con.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    n_emb = con.execute("SELECT COUNT(*) FROM embeddings").fetchone()[0]
    n_ocr = con.execute("SELECT COUNT(*) FROM ocr").fetchone()[0]
    n_tok_files = con.execute(
        "SELECT COUNT(DISTINCT ref_id) FROM tokens WHERE kind='ocr'"
    ).fetchone()[0]
    dupes = con.execute(
        "SELECT COUNT(*) FROM (SELECT uri FROM files"
        " GROUP BY uri HAVING COUNT(*) > 1)"
    ).fetchone()[0]
    if dupes:
        problems.append(f"{dupes} duplicate URIs")
    for name, n in (("embeddings", n_emb), ("ocr", n_ocr)):
        if n != n_files:
            problems.append(f"{name} rows {n} != files rows {n_files}")
    if n_tok_files != n_files:
        problems.append(
            f"token coverage {n_tok_files} files != {n_files} files"
        )
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=500)
    args = ap.parse_args()

    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    rnd = random.Random(7)

    # Pass 1: "killed" halfway (only first half committed).
    con = sqlite3.connect(DB_PATH)
    apply_schema(con)
    for i in range(args.rows // 2):
        index_row(con, i, rnd)
    con.close()  # <-- simulated kill: no checkpoint, no queue persisted

    # Pass 2 (restart): diff everything, index only what is missing.
    con = sqlite3.connect(DB_PATH)
    resumed = [i for i in range(args.rows) if needs_indexing(con, i)]
    for i in resumed:
        index_row(con, i, rnd)

    total = con.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    problems = completeness(con)
    con.close()

    print(f"rows={args.rows} first_pass={args.rows//2}"
          f" resumed={len(resumed)} total={total}")
    if total != args.rows:
        print(f"FAIL: expected {args.rows} rows, got {total}")
        return 1
    if problems:
        print("FAIL completeness:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("PASS: kill-restart resumes with zero duplicates, all rows complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
