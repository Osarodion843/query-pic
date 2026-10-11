"""Replicates the device's EXACT scale corpus (DemoSeed.seedScale LCG) and
computes the per-query text-score distribution that fusion sees.

If >= 50 rows land at score 100 (th == maxToken for every LIMIT-50 row),
the tie-flood explains videos being squeezed out of the top 50.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from text_index import token_search, tokenize  # noqa: E402
import sqlite3

SCALE_WORDS = ["receipt", "sunset", "dog", "birthday", "beach", "invoice",
               "mountain", "dinner", "scan", "park", "ocean", "cake",
               "meeting", "hike", "passport", "groceries", "concert",
               "wedding", "graduation", "picnic", "museum", "street",
               "market", "coffee", "garden", "lake", "forest", "city",
               "bridge", "tower", "festival", "parade", "match", "stadium",
               "camp", "desert", "island", "harbor", "plaza", "theater"]

VIDEO_OCR = [
    ("birthday_party.mp4", "birthday party candles cake singing celebration"),
    ("ocean_waves.mp4", "ocean waves crashing on rocks beach drone footage"),
    ("office_standup.mp4", "office standup meeting sprint board whiteboard"),
    ("hike_trail.mp4", "mountain hike trail forest river view"),
]

DEMO_OCR = [
    "HOME DEPOT receipt total 84 dollars paint supplies",
    "grocery receipt whole foods thirty two fifty fresh produce",
    "passport scan doe travel document identity",
    "sunset over the pier ocean sky evening summer",
    "mountain sunset hike sky evening view",
    "dog playing on green grass park ball pet",
    "happy birthday dinner celebration singing cake friends",
    "beach vlog sunset ocean waves summer vacation",
    "team standup meeting deploy friday beta release work",
    "invoice freelance design work payment due receipt",
    "beach sunrise morning ocean sand summer",
    "birthday cake candles happy celebration party",
]


def main() -> int:
    con = sqlite3.connect(":memory:")
    con.executescript(open(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "schema_v1.sql"),
        encoding="utf-8").read())

    # Exact DemoSeed.seedScale PRNG sequence.
    seed = 12345

    def nxt(m):
        nonlocal seed
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        return seed % m

    def add_file(uri, typ, text):
        cur = con.execute(
            "INSERT INTO files(uri,type,mtime,size,hash) VALUES(?,?,?,?,?)",
            (uri, typ, 1700000000, 2048, uri))
        fid = cur.lastrowid
        if text:
            con.execute("INSERT INTO ocr(file_id,text) VALUES(?,?)",
                        (fid, text))
            for t in tokenize(text):
                con.execute(
                    "INSERT INTO tokens(kind,token,ref_id) VALUES('ocr',?,?)",
                    (t, fid))
        return fid

    video_ids = {}
    for i in range(20000):
        words = [SCALE_WORDS[nxt(40)] for _ in range(4 + nxt(3))]
        text = " ".join(words) + f" doc{i}"
        add_file(f"scale://synthetic-20k/img_{i:05d}.jpg", "photo", text)
        nxt(365)  # daysAgo

    for i, text in enumerate(DEMO_OCR):
        add_file(f"demo://sample-videos/photo_{i:02d}.jpg", "photo", text)
    for name, text in VIDEO_OCR:
        video_ids[name] = add_file(f"demo://sample-videos/{name}",
                                   "video", text)

    print(f"video ids: {video_ids}")
    for q in ["birthday", "ocean", "meeting", "hike", "sunset"]:
        top = token_search(con, "ocr", q, limit=50)
        max_tok = top[0][1] if top else 0
        scores = [round(55 + 35 * (hits / max_tok)) if max_tok else 0
                  for _fid, hits in top]
        at100 = sum(1 for s in scores if s == 100)
        hist = {s: scores.count(s) for s in sorted(set(scores), reverse=True)}
        video_in_window = [(fid, hits) for fid, hits in top
                           if fid in video_ids.values()]
        verdict = ("TIE-FLOOD (>=50 @100)" if at100 >= 50
                   else f"ok (<50 @100, video would rank <= {at100 + 1})")
        print(f'"{q}": window={len(top)} maxHits={max_tok} hist={hist} '
              f'rows@100={at100} videoHits={video_in_window} -> {verdict}')

        # what rank does the matching video get overall?
        for name, fid in video_ids.items():
            hits = con.execute(
                "SELECT COUNT(*) FROM tokens WHERE token=? AND ref_id=?",
                (q, fid)).fetchone()[0]
            if hits:
                print(f"    video {name} th={hits} "
                      f"(text-only score would be "
                      f"{round(55 + 35 * (hits / max_tok))})")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
