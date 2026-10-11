"""Acquire the MIT-licensed CLIP source weights for the clean pipeline.

Option B (2026-10-09): Apple's MobileCLIP weights are research-only
(non-commercial), so the joint model is rebuilt from an MIT-licensed
checkpoint instead of downloaded prebuilt:

  Source (LAION org, Hugging Face, license:mit frontmatter):
    laion/CLIP-ViT-B-32-laion2B-s34B-b79K
      - open_clip_pytorch_model.bin (~350MB fp32, ViT-B/32, 224px, 77 tok)
      - trained on LAION-2B; weights released MIT by LAION.
      - Why this one over OpenAI's original ViT-B/32: OpenAI published no
        explicit weight license (MIT covers their code only); LAION's
        release carries an explicit MIT tag. Same BPE tokenizer as our
        bundled vocab.json/merges.txt (merges byte-identical modulo the
        header comment — verified 2026-10-09).
  Tokenizer: bundled vocab.json + merges.txt already match (reuse as-is).

Then: python tools/convert_clip.py  (Step 2: torch + open_clip export,
ai-edge-torch joint int8 TFLite in the loader's joint layout) and
tools/validate_clip.py (Step 2: int8-vs-float ranking agreement).

Retired: anton96vice/mobileclip2_tflite prebuilt (Apple-weights derived,
research-only license) — kept on disk, never fetched again.

Usage: python tools/fetch_models.py [--models-dir DIR]
Exit 0 when source weights + tokenizer present+valid.
"""
import argparse
import json
import os
import sys
import urllib.request

# MIT-licensed source (see module docstring for the vetting notes).
LAION_BASE = ("https://huggingface.co/laion/"
              "CLIP-ViT-B-32-laion2B-s34B-b79K/resolve/main")
SOURCE_FILE = "open_clip_pytorch_model.bin"
SOURCE_MIN_BYTES = 300_000_000  # fp32 ViT-B/32 ~350MB; reject HTML
# Tokenizer fallback (normally already bundled and valid).
CLIP_BASE = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, "querypic", "sandbox", "models")


def valid_source(path: str) -> tuple[bool, str]:
    try:
        size = os.path.getsize(path)
    except OSError:
        return False, "missing"
    if size < SOURCE_MIN_BYTES:
        return False, f"too small ({size}B) — probably an error page"
    with open(path, "rb") as f:
        magic = f.read(4)
    # PyTorch zip archive (PK..) — the classic .bin format.
    if magic[:2] != b"PK":
        return False, f"bad magic {magic!r} — not a torch checkpoint"
    return True, f"ok ({size/1e6:.1f}MB)"


def fetch(url: str, dest: str, timeout: int = 120) -> bool:
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "QueryPic/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r, \
                open(tmp, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
    except Exception as e:  # noqa: BLE001 — report any network failure plainly
        print(f"  download failed: {e}")
        if os.path.exists(tmp):
            os.remove(tmp)
        return False
    os.replace(tmp, dest)
    return True


def valid_tokenizer(models_dir: str) -> tuple[bool, str]:
    """vocab.json must parse and hold the ~49k CLIP BPE entries."""
    path = os.path.join(models_dir, "vocab.json")
    try:
        with open(path, encoding="utf-8") as f:
            vocab = json.load(f)
    except (OSError, ValueError):
        return False, "missing/unparseable vocab.json"
    if not isinstance(vocab, dict) or len(vocab) < 40000:
        return False, f"suspicious vocab size ({len(vocab)})"
    merges = os.path.join(models_dir, "merges.txt")
    if not os.path.isfile(merges):
        return False, "missing merges.txt"
    return True, f"ok ({len(vocab)} tokens + merges)"


def fetch_text(url: str, dest: str, timeout: int = 60) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": "QueryPic/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
        with open(dest, "wb") as f:
            f.write(data)
    except Exception as e:  # noqa: BLE001 — report plainly
        print(f"  download failed: {e}")
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", default=DEFAULT_DIR)
    ap.add_argument("--source-url",
                    default=f"{LAION_BASE}/{SOURCE_FILE}")
    args = ap.parse_args()

    os.makedirs(args.models_dir, exist_ok=True)
    dest = os.path.join(args.models_dir, SOURCE_FILE)
    ok, why = valid_source(dest)
    if ok:
        print(f"  present: {SOURCE_FILE} {why}")
        ok_source = True
    else:
        print(f"  fetching {SOURCE_FILE} ({why})...")
        print(f"    from {args.source_url}")
        ok_source = fetch(args.source_url, dest)
        if ok_source:
            ok_source, why = valid_source(dest)
            print(f"  validated: {why}")

    tok_ok, tok_why = valid_tokenizer(args.models_dir)
    if tok_ok:
        print(f"  present: vocab.json + merges.txt {tok_why}")
    else:
        print(f"  fetching tokenizer ({tok_why})...")
        ok_v = fetch_text(f"{CLIP_BASE}/vocab.json",
                          os.path.join(args.models_dir, "vocab.json"))
        ok_m = fetch_text(f"{CLIP_BASE}/merges.txt",
                          os.path.join(args.models_dir, "merges.txt"))
        tok_ok, tok_why = valid_tokenizer(args.models_dir)
        print(f"  validated: {tok_why}" if (ok_v and ok_m and tok_ok)
              else "  tokenizer fetch failed")
        tok_ok = ok_v and ok_m and tok_ok

    if ok_source and tok_ok:
        print("PASS: MIT source weights + CLIP tokenizer present and valid")
        print("NEXT: python tools/convert_clip.py "
              "(joint int8 TFLite, loader layout)")
        return 0
    print("FAIL: source weights and/or tokenizer missing.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
