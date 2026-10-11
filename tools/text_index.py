"""Shared token-index contract (host side).

Mirrors IndexDatabase.tokenizeForIndex / tokenSearch in Dart:
  lowercase, split on [^a-z0-9]+, drop tokens < 2 chars, light English
  stemming (plurals + verb forms collapse), dedupe per doc.

The token table replaces FTS5 because sqflite uses the Android system
SQLite, and OEM builds may lack the FTS5 module ("no such module: fts5"
observed on Transsion/itel hardware). Plain tables work everywhere.
"""
import re

_TOKEN_SPLIT = re.compile(r"[^a-z0-9]+")


def stem_token(t: str) -> str:
    """Byte-for-byte mirror of IndexDatabase.stemToken (keep in sync)."""
    stem = t
    if len(stem) > 6 and stem.endswith("ing"):
        stem = stem[:-3]
    elif len(stem) > 5 and stem.endswith("ed"):
        stem = stem[:-2]
    elif len(stem) > 4 and stem.endswith("ies"):
        stem = stem[:-3] + "y"
    elif len(stem) > 4 and (
        stem.endswith("sses")
        or stem.endswith("xes")
        or stem.endswith("zes")
        or stem.endswith("ches")
        or stem.endswith("shes")
        or stem.endswith("ses")
    ):
        stem = stem[:-2]
    elif (
        len(stem) > 4
        and stem.endswith("s")
        and not stem.endswith("ss")
        and not stem.endswith("us")
    ):
        stem = stem[:-1]
    if (
        len(stem) >= 4
        and stem[-1] == stem[-2]
        and stem[-1] in "bdfgklmnprst"
    ):
        stem = stem[:-1]
    return stem if len(stem) >= 2 else t


def tokenize(text: str) -> list[str]:
    return sorted(
        {
            stem_token(t)
            for t in _TOKEN_SPLIT.split(text.lower())
            if len(t) >= 2
        }
    )


def insert_tokens(con, kind: str, ref_id: int, text: str) -> int:
    toks = tokenize(text)
    con.executemany(
        "INSERT OR IGNORE INTO tokens(kind,token,ref_id) VALUES(?,?,?)",
        [(kind, t, ref_id) for t in toks],
    )
    return len(toks)


def token_search(con, kind: str, query: str, limit: int = 50):
    toks = tokenize(query)
    if not toks:
        return []
    conds = ["token IN (%s)" % ",".join("?" for _ in toks)]
    args: list = list(toks)
    for t in toks:
        if len(t) >= 4:
            conds.append("token LIKE ?")
            args.append(f"{t}%")
    return con.execute(
        "SELECT ref_id, COUNT(DISTINCT token) AS hits FROM tokens"
        f" WHERE kind=? AND ({' OR '.join(conds)})"
        " GROUP BY ref_id ORDER BY hits DESC LIMIT ?",
        [kind, *args, limit],
    ).fetchall()


def assert_no_fts5(schema_sql: str) -> None:
    # Strip comments first: mentioning FTS5 in an explanation is fine,
    # creating/using an FTS5 table is what crashes OEM devices.
    code = re.sub(r"--[^\n]*", "", schema_sql)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    if re.search(r"fts5", code, re.I):
        raise AssertionError(
            "schema creates/uses FTS5 — unavailable on some OEM SQLite"
        )
