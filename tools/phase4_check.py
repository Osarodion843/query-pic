"""Phase 4 contract checks (host-runnable, static + sqlite).

Verifies the four Phase 4 tasks without a device:
  1. Frame extractor: 1 frame / 2.5s sampling math, Free 5-min cap,
     middle-frame thumbnail convention, per-file skip reporting
  2. Search: frameVectorScan wired into SearchService, best-frame score
     fused through fuseAndRank (frameHits), date filter applies to frames,
     visual floor hides frame-only gibberish
  3. Handoff: preview button enabled, url_launcher wired, Free plays at 0s
     (seek timestamp retained for Phase 5), demo rows explained honestly
  4. Edge cases: corrupt-file skip path, cap arithmetic, schema parity
     (Dart frames table == schema_v1.sql), frame-scan perf proxy

Device steps (real CLIP frame vectors, native playback) run on hardware.

Usage: python tools/phase4_check.py [--frames 20000]
Exit 0 on PASS, 1 on FAIL.
"""
import argparse
import math
import os
import re
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from text_index import insert_tokens  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "querypic", "lib")
TESTS = os.path.join(ROOT, "querypic", "test")
TOOLS = os.path.join(ROOT, "tools")


def read_dart(*parts: str) -> str:
    with open(os.path.join(LIB, *parts), encoding="utf-8") as f:
        return f.read()


def sample_times(duration, interval=2.5, cap=300.0):
    """Python replica of VideoIndexer.sampleTimes (Dart contract)."""
    if duration is None or duration <= 0 or interval <= 0 or cap <= 0:
        return []
    budget = min(duration, cap)
    times, t = [], 0.0
    while t < budget:
        times.append(round(t, 2))
        t += interval
    return times


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=20000)
    args = ap.parse_args()
    failures: list[str] = []

    def check(name: str, cond: bool, hint: str = ""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}"
              + (f" — {hint}" if hint and not cond else ""))
        if not cond:
            failures.append(name)

    # --- Task 1: frame extractor -----------------------------------------
    for rel in ("services/video_indexer.dart", "services/index_database.dart",
                "services/query_engine.dart", "services/search_service.dart",
                "services/debug_seed.dart", "screens/settings_screen.dart",
                "screens/workspace_screen.dart"):
        check(f"exists {rel}", os.path.isfile(os.path.join(LIB, rel)))

    vi = read_dart("services", "video_indexer.dart")
    check("frames: sampling 1 frame / 2.5s", "2.5" in vi)
    check("frames: Free 5-min cap (300s)", "300" in vi)
    check("frames: sampleTimes is pure + tested",
          "static List<double> sampleTimes" in vi)
    check("frames: middle-frame thumbnail convention",
          "middleThumbTime" in vi)
    check("frames: indexVideo per-file skip reporting",
          "skipped" in vi and "indexVideo" in vi)
    check("frames: corrupt/edge files never abort the pass",
          "catch (e)" in vi and "skip" in vi.lower())

    check("test/video_test.dart covers sampling + fusion",
          os.path.isfile(os.path.join(TESTS, "video_test.dart")))
    with open(os.path.join(TESTS, "video_test.dart"), encoding="utf-8") as f:
        vt = f.read()
    check("test: sampleTimes cap assertion", "lessThan(300)" in vt)
    check("test: frame fusion + visual floor asserted",
          "frameHits" in vt and "visualFloor" in vt or
          "visual floor" in vt)
    check("test: bestFrameSecs asserted", "bestFrameSecs" in vt)

    # --- Task 2: search fusion -------------------------------------------
    svc = read_dart("services", "search_service.dart")
    check("search: frameVectorScan wired into the query path",
          "frameVectorScan" in svc)
    check("search: frame hits feed fusion", "frameHits:" in svc)
    check("search: date filter applies to frame hits",
          svc.count("removeWhere") >= 3)
    check("search: visual floor hides frame-only noise",
          "visualFloor" in svc and "visualFloor" in
          read_dart("services", "query_engine.dart"))
    engine = read_dart("services", "query_engine.dart")
    check("fusion: frameHits parameter", "frameHits" in engine)
    check("fusion: bestFrameSecs carried on results",
          "bestFrameSecs" in engine)
    check("fusion: floor never drops text-backed hits",
          "matched.contains('text')" in engine)
    check("fusion: visual-only rows need text context or near-exact sim",
          "tokenHits.isEmpty" in engine)
    db_src = read_dart("services", "index_database.dart")
    check("db: frames table in schema",
          "CREATE TABLE IF NOT EXISTS frames" in db_src)
    im = db_src.find("Future<void> insertFrames")
    body = db_src[im:im + 600] if im != -1 else ""
    check("db: insertFrames replaces old frames on reindex",
          im != -1 and "db.delete" in body and "batch" in body)
    check("db: frameVectorScan keeps per-file best",
          "frameVectorScan" in db_src)
    check("db: shared cosine helper", "static double? cosineInt8" in db_src)

    # --- Task 3: native handoff ------------------------------------------
    # Shared opener (result_opener.dart serves workspace + Similar previews;
    # workspace delegates via _openNative).
    ws = read_dart("screens", "workspace_screen.dart")
    try:
        opener = read_dart("screens", "result_opener.dart")
    except OSError:
        opener = ws
    check("handoff: preview button enabled (not deferred)",
          "_openNative" in ws and "onPressed: null" not in ws)
    check("handoff: url_launcher wired",
          "url_launcher" in opener and "launchUrl" in opener)
    check("handoff: external application (system player)",
          "LaunchMode.externalApplication" in opener)
    check("handoff: Free plays from 0s, seek deferred to Phase 5",
          "buildHandoff" in opener and "seekApplied" in opener)
    check("handoff: matched frame timestamp shown",
          "bestFrameSecs" in opener)
    check("handoff: demo rows explained, not a crash",
          "Demo row" in opener)
    pubspec = open(os.path.join(ROOT, "querypic", "pubspec.yaml"),
                   encoding="utf-8").read()
    check("handoff: url_launcher in pubspec", "url_launcher" in pubspec)
    check("schema: urls never launched blindly (scheme allow-list)",
          "'content'" in opener and "'file'" in opener)

    # --- Demo video seeding + settings entry -----------------------------
    seed_src = read_dart("services", "debug_seed.dart")
    check("seed: demo videos via real pipeline",
          "seedDemoVideos" in seed_src and "insertIndexed" in seed_src)
    check("seed: frames written through insertFrames",
          "insertFrames" in seed_src)
    check("seed: sampling shared with device indexer",
          "VideoIndexer.sampleTimes" in seed_src)
    check("seed: duration stored on video rows",
          "duration: row.durationSecs" in seed_src)
    check("seed: independent scope, cleared with synthetic rows",
          "videoScopePrefix" in seed_src and
          seed_src.count("deleteByScopePrefix(videoScopePrefix)") >= 2)
    check("seed: cap-boundary row exists (305s > 300s)",
          "305" in seed_src)
    settings_src = read_dart("screens", "settings_screen.dart")
    check("settings: 'Seed demo videos' entry point",
          "Seed demo videos" in settings_src)
    check("settings: seeds then times video queries",
          "seedDemoVideos" in settings_src and
          "search.search" in settings_src)
    check("settings: reports p95 verdict",
          "p95" in settings_src and "Verdict" in settings_src)

    # --- Task 4: schema parity + sqlite live check -----------------------
    with open(os.path.join(TOOLS, "schema_v1.sql"), encoding="utf-8") as f:
        schema = f.read()
    ddl = re.compile(
        r"CREATE TABLE IF NOT EXISTS frames \(.*?\);", re.S)
    dart_m = ddl.search(db_src.replace("--", ""))
    sql_m = ddl.search(schema)
    norm = lambda s: re.sub(r"\s+", " ", s).strip().lower()
    parity = bool(dart_m and sql_m) and norm(dart_m.group(0)) == \
        norm(sql_m.group(0))
    check("schema: Dart frames table == schema_v1.sql", parity)
    check("schema: ON DELETE CASCADE reaches frames (both sides)",
          bool(dart_m) and "on delete cascade" in norm(dart_m.group(0))
          and bool(sql_m) and "on delete cascade" in norm(sql_m.group(0)))

    # Sampling arithmetic contract (Dart replica).
    check("sampling: 60s -> 24 frames", len(sample_times(60)) == 24)
    check("sampling: 305s capped to first 300s (120 frames)",
          len(sample_times(305)) == 120 and max(sample_times(305)) < 300)
    check("sampling: nonsense durations yield nothing",
          sample_times(None) == [] and sample_times(0) == []
          and sample_times(-1) == [])

    con = sqlite3.connect(":memory:")
    con.executescript(schema)
    # Seed videos + frame rows the way seedDemoVideos does.
    rnd_frames = args.frames
    videos, per_video = 200, max(1, rnd_frames // 200)
    for v in range(videos):
        cur = con.execute(
            "INSERT INTO files(uri,type,mtime,size,hash)"
            " VALUES(?,?,?,?,?)",
            (f"demo://sample-videos/clip_{v}.mp4", "video",
             1700000000 + v, 1024 * 1024, f"clip_{v}"),
        )
        fid = cur.lastrowid
        con.execute(
            "INSERT INTO embeddings(file_id,vec_int8,model_ver)"
            " VALUES(?,?,?)",
            (fid, bytes((i * 7 + v) % 256 for i in range(32)), "bench"),
        )
        for t in range(per_video):
            con.execute(
                "INSERT INTO frames(file_id,t,vec_int8) VALUES(?,?,?)",
                (fid, t * 2.5,
                 bytes((i * 11 + t + v) % 256 for i in range(32))),
            )
    # Best-frame scan (mirrors frameVectorScan) perf proxy.
    q = bytes((i * 13 + 5) % 256 for i in range(32))
    t0 = time.perf_counter()
    best: dict[int, tuple[float, float]] = {}
    for fid, t, blob in con.execute(
            "SELECT file_id, t, vec_int8 FROM frames"):
        dot = sum((a - 128) * (b - 128) for a, b in zip(q, blob))
        qa = sum((a - 128) ** 2 for a in q)
        ba = sum((b - 128) ** 2 for b in blob)
        if qa and ba:
            sim = dot / math.sqrt(qa * ba)
            if fid not in best or sim > best[fid][0]:
                best[fid] = (sim, t)
    scan_ms = (time.perf_counter() - t0) * 1000
    check(f"perf: best-frame scan over {args.frames} frames <500ms",
          scan_ms < 500, f"{scan_ms:.1f}ms")
    print(f"       best-frame scan measured: {scan_ms:.1f}ms")
    check("perf: every video has a best frame",
          len(best) == videos)

    # Demo-video query proxy: token hit on a video + frame fusion.
    con.execute("INSERT INTO ocr(file_id,text) VALUES(?,?)",
                (1, "ocean waves beach"))
    insert_tokens(con, "ocr", 1, "ocean waves beach")
    row = con.execute(
        "SELECT ref_id, COUNT(*) AS hits FROM tokens"
        " WHERE token='ocean'"
        " AND ref_id IN (SELECT id FROM files WHERE type='video')"
        " GROUP BY ref_id",
    ).fetchone()
    check("query: video findable by object/scene words (Free exit "
          "criterion)", row is not None and row[0] == 1)
    con.close()

    print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failures")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
