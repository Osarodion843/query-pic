"""Exact host replica of the device "happy birthday" STT query.

Corpus: byte-exact Dart-LCG scale rows (seed 12345) + exact demo/video
strings + stub transcripts. Embeddings: verified-identical stub_embed
(parity-checked 6/6 vs `dart run`). Replicates SearchService._run with the
transcript merge + crowded follow-up, then fuseAndRank with the Phase 4/5
rules (text cap 90, context gate, floor 50, video-first ties).

Usage: python tools/diag_stt.py [--transcribe-library]
  --transcribe-library: also transcribe the 3 demo-library videos
  (simulates the user having tapped Settings > Transcribe videos while Pro)

Exit 0. Prints the full score distribution around the birthday video.
"""
import math
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diag_phase4 import stub_embed  # noqa: E402
from text_index import token_search, tokenize  # noqa: E402

SCALE_WORDS = ["receipt", "sunset", "dog", "birthday", "beach", "invoice",
               "mountain", "dinner", "scan", "park", "ocean", "cake",
               "meeting", "hike", "passport", "groceries", "concert",
               "wedding", "graduation", "picnic", "museum", "street",
               "market", "coffee", "garden", "lake", "forest", "city",
               "bridge", "tower", "festival", "parade", "match", "stadium",
               "camp", "desert", "island", "harbor", "plaza", "theater"]

DEMO_ROWS = [  # (uri, ocr, is_video) — exact debug_seed.dart strings
    ("receipt_home_depot.jpg", "HOME DEPOT receipt total 84 dollars paint supplies", False),
    ("receipt_grocery.jpg", "grocery receipt whole foods thirty two fifty fresh produce", False),
    ("passport_scan.jpg", "passport scan doe travel document identity", False),
    ("sunset_pier.jpg", "sunset over the pier ocean sky evening summer", False),
    ("sunset_mountains.jpg", "mountain sunset hike sky evening view", False),
    ("dog_park.jpg", "dog playing on green grass park ball pet", False),
    ("birthday_dinner.mp4", "happy birthday dinner celebration singing cake friends", True),
    ("beach_vlog.mp4", "beach vlog sunset ocean waves summer vacation", True),
    ("standup_meeting.mp4", "team standup meeting deploy friday beta release work", True),
    ("invoice_freelance.jpg", "invoice freelance design work payment due receipt", False),
    ("beach_sunrise.jpg", "beach sunrise morning ocean sand summer", False),
    ("birthday_cake.jpg", "birthday cake candles happy celebration party", False),
]

VIDEO_ROWS = [  # (uri, ocr, duration, scenes)
    ("birthday_party.mp4", "birthday party candles cake singing celebration",
     74.0, ["birthday", "cake", "candles", "singing"]),
    ("ocean_waves.mp4", "ocean waves crashing on rocks beach drone footage",
     145.0, ["ocean", "waves", "beach", "sunset"]),
    ("office_standup.mp4", "office standup meeting sprint board whiteboard",
     62.0, ["meeting", "whiteboard", "office", "sprint"]),
    ("hike_trail.mp4", "mountain hike trail forest river view",
     305.0, ["hike", "forest", "river", "mountain"]),
]

# Exact StubSttEngine.vocabFor segments.
TRANSCRIPTS = {
    "birthday_party.mp4": ["happy birthday to you",
                            "cake and candles celebration",
                            "singing with friends tonight"],
    "ocean_waves.mp4": ["ocean waves on the beach",
                        "sunset over the water",
                        "summer vacation footage"],
    "office_standup.mp4": ["team standup meeting",
                            "sprint board review",
                            "office deploy friday"],
    "hike_trail.mp4": ["mountain hike trail",
                       "forest river view",
                       "camping under stars"],
    "birthday_dinner.mp4": ["happy birthday to you",
                             "cake and candles celebration",
                             "singing with friends tonight"],
    "beach_vlog.mp4": ["ocean waves on the beach",
                       "sunset over the water",
                       "summer vacation footage"],
    "standup_meeting.mp4": ["team standup meeting",
                             "sprint board review",
                             "office deploy friday"],
}


def cosine(a, b):
    dot = qa = ba = 0
    for x, y in zip(a, b):
        u, v = x - 128, y - 128
        dot += u * v
        qa += u * u
        ba += v * v
    if qa == 0 or ba == 0:
        return None
    return dot / math.sqrt(qa * ba)


def sample_times(duration, interval=2.5, cap=300.0):
    budget = min(duration, cap)
    times, t = [], 0.0
    while t < budget:
        times.append(round(t, 2))
        t += interval
    return times


def main() -> int:
    transcribe_library = "--transcribe-library" in sys.argv
    con = sqlite3.connect(":memory:")
    con.executescript(open(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "schema_v1.sql"),
        encoding="utf-8").read())

    seed = 12345

    def nxt(m):
        nonlocal seed
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        return seed % m

    def add_file(uri, typ, text, vec_text):
        cur = con.execute(
            "INSERT INTO files(uri,type,mtime,size,hash) VALUES(?,?,?,?,?)",
            (uri, typ, 1700000000, 2048, uri))
        fid = cur.lastrowid
        con.execute("INSERT INTO embeddings(file_id,vec_int8,model_ver)"
                    " VALUES(?,?,?)", (fid, bytes(stub_embed(vec_text)), "x"))
        if text:
            con.execute("INSERT INTO ocr(file_id,text) VALUES(?,?)",
                        (fid, text))
            for t in tokenize(text):
                con.execute(
                    "INSERT INTO tokens(kind,token,ref_id)"
                    " VALUES('ocr',?,?)", (t, fid))
        return fid

    def add_transcript(fid, segments):
        seen = set()
        for i, text in enumerate(segments):
            con.execute("INSERT INTO transcripts(file_id,t_start,t_end,text)"
                        " VALUES(?,?,?,?)", (fid, i * 10.0, i * 10.0 + 10, text))
            for t in tokenize(text):
                if t not in seen:
                    seen.add(t)
                    con.execute(
                        "INSERT INTO tokens(kind,token,ref_id)"
                        " VALUES('transcript',?,?)", (t, fid))

    # 1) scale rows (exact LCG order: count first, then words, then daysAgo)
    for i in range(20000):
        words = [SCALE_WORDS[nxt(40)] for _ in range(4 + nxt(3))]
        text = " ".join(words) + f" doc{i}"
        add_file(f"scale://synthetic-20k/img_{i:05d}.jpg", "photo", text, text)
        nxt(365)

    # 2) demo rows
    demo_ids = {}
    for uri, ocr, is_vid in DEMO_ROWS:
        demo_ids[uri] = add_file(f"demo://sample-library/{uri}",
                                 "video" if is_vid else "photo", ocr, ocr)

    # 3) demo videos + frames
    video_ids = {}
    for uri, ocr, dur, scenes in VIDEO_ROWS:
        fid = add_file(f"demo://sample-videos/{uri}", "video", ocr, ocr)
        video_ids[uri] = fid
        for i, t in enumerate(sample_times(dur)):
            con.execute("INSERT INTO frames(file_id,t,vec_int8)"
                        " VALUES(?,?,?)",
                        (fid, t, bytes(stub_embed(scenes[i % len(scenes)]))))

    # 4) transcripts: 4 sample-videos always; library optionally
    for uri, _, _, _ in VIDEO_ROWS:
        add_transcript(video_ids[uri], TRANSCRIPTS[uri])
    if transcribe_library:
        for uri in ("birthday_dinner.mp4", "beach_vlog.mp4",
                    "standup_meeting.mp4"):
            add_transcript(demo_ids[uri], TRANSCRIPTS[uri])

    # ---- exact _run replica for "happy birthday" ----
    q = "happy birthday"
    qtokens = tokenize(q)
    print(f"query tokens: {qtokens}  "
          f"(transcribe_library={transcribe_library})")

    token_rows = token_search(con, "ocr", q, limit=50)
    speech_rows = token_search(con, "transcript", q, limit=500)
    token_hits: dict[int, int] = {}
    for fid, hits in token_rows:
        token_hits[fid] = token_hits.get(fid, 0) + hits
    ocr_ids = set(token_hits)
    crowded = []
    for fid, hits in speech_rows:
        token_hits[fid] = token_hits.get(fid, 0) + hits
        if fid not in ocr_ids:
            crowded.append(fid)
    print(f"ocr window={len(token_rows)} speech rows={len(speech_rows)} "
          f"crowded follow-up ids={len(crowded)}")
    if crowded:
        ph = ",".join("?" * len(crowded))
        tp = ",".join("?" * len(qtokens))
        for fid, hits in con.execute(
                "SELECT ref_id, COUNT(*) FROM tokens WHERE kind='ocr' "
                f"AND token IN ({tp}) AND ref_id IN ({ph}) GROUP BY ref_id",
                (*qtokens, *crowded)):
            token_hits[fid] = token_hits.get(fid, 0) + hits

    max_token = max(token_hits.values())
    print(f"maxToken={max_token}")

    qvec = stub_embed(q)
    vec_scores = {}
    for fid, blob in con.execute("SELECT file_id, vec_int8 FROM embeddings"):
        s = cosine(qvec, list(blob))
        if s is not None:
            vec_scores[fid] = s
    vector_hits = dict(sorted(vec_scores.items(), key=lambda e: -e[1])[:50])

    frame_best = {}
    for fid, t, blob in con.execute("SELECT file_id, t, vec_int8 FROM frames"):
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

    fused = []
    for fid in ids:
        f = rows.get(fid)
        if f is None:
            continue
        matched = set()
        th = token_hits.get(fid)
        vh = vector_hits.get(fid)
        fh = frame_hits.get(fid)
        if fh is not None and (vh is None or fh[0] > vh):
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
            if not token_hits and sim < 0.9:
                continue
            score = 100 * (sim + 1) / 2
        score = round(score)
        if "text" not in matched and score < 50:
            continue
        fused.append((fid, f[1], f[2], score, sorted(matched),
                      th, round(vh, 3) if vh is not None else None))
    fused.sort(key=lambda e: (-e[3], e[0]))
    top = fused[:50]

    bfid = video_ids["birthday_party.mp4"]
    print(f"\nbirthday_party id={bfid} merged th={token_hits.get(bfid)} "
          f"vec={'%.3f' % vector_hits.get(bfid, float('nan'))} "
          f"frame={frame_hits.get(bfid)}")
    rank = next((i for i, r in enumerate(top) if r[0] == bfid), None)
    print(f"birthday_party rank: "
          f"{'#%d' % (rank + 1) if rank is not None else 'CUT'}")
    above = [r for r in top
             if rank is None or top.index(r) < rank] if rank else top
    print(f"\nrows scoring above-or-tied (top {len(top)} shown to rank):")
    for i, (fid, uri, typ, sc, m, th, vh) in enumerate(top[:60]):
        mark = " <== birthday_party" if fid == bfid else ""
        short = uri.split("/")[-1]
        print(f"  #{i + 1:2d} {sc:3d} {typ:5s} th={th} vh={vh} {m} "
              f"{short}{mark}")
        if i == 59:
            break
    print(f"\ncutoff(50th)={top[49][3] if len(top) >= 50 else 'n/a'} "
          f"n={len(top)}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
