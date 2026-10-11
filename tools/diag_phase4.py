"""Phase 4 diagnosis: replicate the exact device query path on host.

Scenario mirrors the device run:
  20k scale rows + 12 demo rows + 4 demo videos (233 frames)
  queries: birthday / ocean / meeting / hike / sunset
Path: tokenSearch(limit 50) + vectorScan(limit 50) + frameVectorScan(50)
      -> fuseAndRank(visualFloor 50) -> sort -> limit 50 -> count videos.
"""
import math
import os
import random
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from text_index import insert_tokens, token_search, tokenize  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(ROOT, "tools", "schema_v1.sql"), encoding="utf-8") as f:
    schema = f.read()


def stub_embed(text: str, dim: int = 32) -> list[int]:
    """Exact mirror of lib/services/stub_embed.dart stubEmbedText —
    FNV-1a (32-bit) over code units, then xorshift32 expanding one byte
    per dimension. Keep in sync with the Dart contract."""
    h = 0x811C9DC5
    for ch in text:
        h = (h ^ ord(ch)) & 0xFFFFFFFF
        h = (h * 0x01000193) & 0xFFFFFFFF
    if h == 0:
        h = 0x9E3779B9
    out = []
    for _ in range(dim):
        h ^= (h << 13) & 0xFFFFFFFF
        h ^= h >> 17
        h ^= (h << 5) & 0xFFFFFFFF
        h &= 0xFFFFFFFF
        out.append(h & 0xFF)
    return out


def cosine(a, b):
    if len(a) != len(b) or not a:
        return None
    dot = qa = ba = 0
    for x, y in zip(a, b):
        u, v = x - 128, y - 128
        dot += u * v
        qa += u * u
        ba += v * v
    if qa == 0 or ba == 0:
        return None
    return dot / math.sqrt(qa * ba)


SCALE_WORDS = ["receipt", "sunset", "dog", "birthday", "beach", "invoice",
               "mountain", "dinner", "scan", "park", "ocean", "cake",
               "meeting", "hike", "passport", "groceries", "concert",
               "wedding", "graduation", "picnic", "museum", "street",
               "market", "coffee", "garden", "lake", "forest", "city",
               "bridge", "tower", "festival", "parade", "match", "stadium",
               "camp", "desert", "island", "harbor", "plaza", "theater"]

DEMO = [
    ("receipt_home_depot.jpg", "HOME DEPOT receipt total 84 dollars paint supplies"),
    ("receipt_grocery.jpg", "grocery receipt whole foods thirty two fifty fresh produce"),
    ("passport_scan.jpg", "passport scan doe travel document identity"),
    ("sunset_pier.jpg", "sunset over the pier ocean sky evening summer"),
    ("sunset_mountains.jpg", "mountain sunset hike sky evening view"),
    ("dog_park.jpg", "dog playing on green grass park ball pet"),
    ("birthday_dinner.mp4", "happy birthday dinner celebration singing cake friends"),
    ("beach_vlog.mp4", "beach vlog sunset ocean waves summer vacation"),
    ("standup_meeting.mp4", "team standup meeting deploy friday beta release work"),
    ("invoice_freelance.jpg", "invoice freelance design work payment due receipt"),
    ("beach_sunrise.jpg", "beach sunrise morning ocean sand summer"),
    ("birthday_cake.jpg", "birthday cake candles happy celebration party"),
]

VIDEOS = [
    ("birthday_party.mp4", "birthday party candles cake singing celebration",
     74.0, ["birthday", "cake", "candles", "singing"]),
    ("ocean_waves.mp4", "ocean waves crashing on rocks beach drone footage",
     145.0, ["ocean", "waves", "beach", "sunset"]),
    ("office_standup.mp4", "office standup meeting sprint board whiteboard",
     62.0, ["meeting", "whiteboard", "office", "sprint"]),
    ("hike_trail.mp4", "mountain hike trail forest river view",
     305.0, ["hike", "forest", "river", "mountain"]),
]


def sample_times(duration, interval=2.5, cap=300.0):
    budget = min(duration, cap)
    times, t = [], 0.0
    while t < budget:
        times.append(round(t, 2))
        t += interval
    return times


def insert_file(con, uri, is_video, ocr, days_ago, size=2048):
    mtime = 1700000000 - days_ago * 86400
    cur = con.execute(
        "INSERT INTO files(uri,type,mtime,size,hash) VALUES(?,?,?,?,?)",
        (uri, "video" if is_video else "photo", mtime, size,
         f"{uri}|{mtime}|{size}"),
    )
    fid = cur.lastrowid
    con.execute("INSERT INTO embeddings(file_id,vec_int8,model_ver)"
                " VALUES(?,?,?)",
                (fid, bytes(stub_embed(ocr)), "diag"))
    if ocr:
        con.execute("INSERT INTO ocr(file_id,text) VALUES(?,?)", (fid, ocr))
        insert_tokens(con, "ocr", fid, ocr)
    return fid


def main() -> int:
    con = sqlite3.connect(":memory:")
    con.executescript(schema)
    rnd = random.Random(11)

    # 1) 20k scale rows (as DemoSeed.seedScale does).
    for i in range(20000):
        words = [rnd.choice(SCALE_WORDS)
                 for _ in range(4 + rnd.randrange(3))]
        ocr = " ".join(words) + f" doc{i}"
        insert_file(con, f"scale://synthetic-20k/img_{i:05d}.jpg",
                    False, ocr, rnd.randrange(365))
    # 2) demo rows.
    for uri, ocr in DEMO:
        insert_file(con, f"demo://sample-library/{uri}", uri.endswith(".mp4"),
                    ocr, 3)
    # 3) demo videos + frames (as seedDemoVideos does).
    video_ids = {}
    for uri, ocr, dur, scenes in VIDEOS:
        fid = insert_file(con, f"demo://sample-videos/{uri}", True, ocr, 2,
                          size=1024 * 1024)
        video_ids[fid] = uri
        for i, t in enumerate(sample_times(dur)):
            con.execute("INSERT INTO frames(file_id,t,vec_int8) VALUES(?,?,?)",
                        (fid, t, bytes(stub_embed(scenes[i % len(scenes)]))))
    n_frames = con.execute("SELECT COUNT(*) FROM frames").fetchone()[0]
    n_files = con.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    n_videos = con.execute(
        "SELECT COUNT(*) FROM files WHERE type='video'").fetchone()[0]
    print(f"seeded: {n_files} files ({n_videos} videos), {n_frames} frames")

    # 4) Query path replica.
    for q in ["birthday", "ocean", "meeting", "hike", "sunset", "zxqvkw"]:
        token_rows = token_search(con, "ocr", q, limit=50)
        token_hits = {r[0]: r[1] for r in token_rows}

        qvec = stub_embed(q)
        vec_scores = {}
        for fid, blob in con.execute(
                "SELECT file_id, vec_int8 FROM embeddings"):
            s = cosine(qvec, list(blob))
            if s is not None:
                vec_scores[fid] = s
        vector_hits = dict(sorted(vec_scores.items(),
                                  key=lambda e: -e[1])[:50])

        frame_best = {}
        for fid, t, blob in con.execute(
                "SELECT file_id, t, vec_int8 FROM frames"):
            s = cosine(qvec, list(blob))
            if s is None:
                continue
            if fid not in frame_best or s > frame_best[fid][0]:
                frame_best[fid] = (s, t)
        frame_hits = dict(sorted(frame_best.items(),
                                 key=lambda e: -e[1][0])[:50])

        ids = set(token_hits) | set(vector_hits) | set(frame_hits)
        rows = {r[0]: r for r in con.execute(
            "SELECT id, uri, type, mtime FROM files "
            f"WHERE id IN ({','.join('?' * len(ids))})", list(ids))}

        max_token = max(token_hits.values(), default=0)
        fused = []
        for fid in ids:
            f = rows.get(fid)
            if f is None:
                continue
            matched = set()
            th = token_hits.get(fid)
            vh = vector_hits.get(fid)
            fh = frame_hits.get(fid)
            if fh is not None:
                if vh is None or fh[0] > vh:
                    vh = fh[0]
            if th is not None and vh is not None:
                matched |= {"text", "visual"}
                blended = 60 * (th / max_token) + 40 * ((vh + 1) / 2)
                lone = 55 + 35 * (th / max_token)
                score = blended if blended > lone else lone
            elif th is not None:
                matched.add("text")
                score = 55 + 35 * (th / max_token)
            else:
                matched.add("visual")
                sim = vh if vh is not None else -1
                # Mirror of the stub-era context gate in fuseAndRank.
                if not token_hits and sim < 0.9:
                    continue
                score = 100 * (sim + 1) / 2
            rounded = round(score)
            if "text" not in matched and rounded < 50:
                continue
            fused.append((fid, f[1], f[2], rounded))
        fused.sort(key=lambda e: (-e[3], e[0]))
        top = fused[:50]
        vids = [t for t in top if t[2] == "video"]
        print(f'"{q}": {len(top)} hits, {len(vids)} videos')
        if q == "zxqvkw":
            # Gibberish probe: the context gate must yield a clean empty
            # state (no text hits -> no visual-only rows admitted).
            print("   EXPECTED-EMPTY" if not top else "   GIBBERISH LEAK")
            continue
        for fid, uri, typ, sc in top[:3]:
            fh = frame_hits.get(fid)
            print(f"   #{sc} {typ:5s} {uri}"
                  + (f" (frame t={fh[1]} sim={fh[0]:.2f})" if fh else ""))
        if not vids:
            # Diagnose: where did the matching videos go?
            for uri, ocr, dur, scenes in VIDEOS:
                fid = con.execute(
                    "SELECT id FROM files WHERE uri=?",
                    (f"demo://sample-videos/{uri}",)).fetchone()[0]
                print(f"   diag {uri}: in_token={fid in token_hits} "
                      f"in_vector={fid in vector_hits} "
                      f"in_frame={fid in frame_hits} "
                      f"frame_hit={frame_hits.get(fid)}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
