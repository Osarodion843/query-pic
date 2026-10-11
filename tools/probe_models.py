"""Identify which .tflite file is the image tower vs text tower.

Tries, in order:
  1. A real TFLite interpreter (tflite_runtime / ai_edge_litert / tensorflow
     if installed) and prints authoritative input/output details.
  2. Binary forensics fallback: file sizes + printable-string scan for tower
     markers (text: input_ids/attention_mask/token; image: pixel/image
     preprocessing). Needs no extra packages.

tflite-runtime publishes no wheel for Python 3.14, which is why path 2
exists — the verdict below is evidence-based, and the device confirms it
definitively via interpreter input shapes before FeatureExtractor wiring.

Usage: python tools/probe_models.py [--models-dir DIR]
Exit 0 with a mapping verdict, 1 if files are missing/invalid.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch_models import valid_tflite  # noqa: E402

TEXT_MARKERS = ("input_ids", "attention_mask", "token_type",
                "token_embedding", "text_encoder", "positional_embedding")
IMAGE_MARKERS = ("pixel_values", "rescale", "image_encoder",
                 "patch_embed", "class_token")


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little", signed=False)


def _u16(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 2], "little", signed=False)


def _field(b: bytes, table: int, fi: int):
    """Offset of field fi's data, or None if absent."""
    vtable = table - int.from_bytes(b[table:table + 4], "little",
                                     signed=True)
    if 4 + 2 * fi >= _u16(b, vtable):
        return None
    off = _u16(b, vtable + 4 + 2 * fi)
    return table + off if off else None


def _vec_u32(b: bytes, field: int) -> list:
    start = field + _u32(b, field)
    n = _u32(b, start)
    return [_u32(b, start + 4 + 4 * i) for i in range(n)]


def _vec_tables(b: bytes, field: int) -> list:
    start = field + _u32(b, field)
    n = _u32(b, start)
    return [start + 4 + 4 * i + _u32(b, start + 4 + 4 * i)
            for i in range(n)]


def _vec_i32(b: bytes, field: int) -> list:
    start = field + _u32(b, field)
    n = _u32(b, start)
    return [int.from_bytes(b[start + 4 + 4 * i:start + 8 + 4 * i], "little",
                           signed=True) for i in range(n)]


def _str(b: bytes, field: int) -> str:
    start = field + _u32(b, field)
    n = _u32(b, start)
    return b[start + 4:start + 4 + n].decode("utf-8", "replace")


def fbs_shapes(path: str):
    """Read subgraph-0 input/output tensor (name, shape) straight from the
    TFLite FlatBuffer. No interpreter needed. Raises on malformed files."""
    with open(path, "rb") as f:
        b = f.read()
    if b[4:8] != b"TFL3":
        raise ValueError("not a TFLite flatbuffer")
    model = _u32(b, 0)
    subgraphs = _field(b, model, 2)  # Model.subgraphs
    sg = _vec_tables(b, subgraphs)[0]
    tensors = _vec_tables(b, _field(b, sg, 0))  # SubGraph.tensors
    out = []
    for fi, tag in ((1, "in"), (2, "out")):  # SubGraph.inputs/outputs
        fpos = _field(b, sg, fi)
        if fpos is None:
            continue
        for ti in _vec_i32(b, fpos):
            t = tensors[ti]
            shape = _vec_i32(b, _field(b, t, 0))  # Tensor.shape
            name = _str(b, _field(b, t, 3))  # Tensor.name
            out.append((tag, name, shape))
    return out


def try_interpreter(path: str):
    """Return (input_details, output_details) or None if no runtime."""
    for mod, attr in (("tflite_runtime.interpreter", "Interpreter"),
                      ("ai_edge_litert.interpreter", "Interpreter"),
                      ("tensorflow.lite", "Interpreter")):
        try:
            parts = mod.split(".")
            m = __import__(parts[0])
            for p in parts[1:]:
                m = getattr(m, p)
            interp = getattr(m, attr)(model_path=path)
            interp.allocate_tensors()
            return interp.get_input_details(), interp.get_output_details()
        except Exception:  # noqa: BLE001 — try next runtime
            continue
    return None


def string_scan(path: str, markers: tuple) -> dict:
    with open(path, "rb") as f:
        blob = f.read()
    strings = set(re.findall(rb"[ -~]{5,}", blob))
    text = b"\n".join(strings).lower()
    return {m: (m.encode() in text) for m in markers}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models-dir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "querypic", "sandbox", "models"))
    args = ap.parse_args()

    # Legacy clip_image_s2.tflite was renamed to clip_joint_s2.tflite;
    # clip_text_s2.tflite was deleted (zero subgraphs, unrunnable).
    legacy = os.path.join(args.models_dir, "clip_image_s2.tflite")
    joint = os.path.join(args.models_dir, "clip_joint_s2.tflite")
    if os.path.exists(legacy) and not os.path.exists(joint):
        print(f"  renaming legacy clip_image_s2.tflite -> clip_joint_s2.tflite")
        os.rename(legacy, joint)
    files = {"clip_joint_s2.tflite": joint}
    ok_all = True
    evidence = {}
    for name, path in files.items():
        ok, why = valid_tflite(path)
        size_mb = os.path.getsize(path) / 1e6 if os.path.exists(path) else 0
        print(f"{name}: {why} ({size_mb:.1f}MB)")
        if not ok:
            ok_all = False
            continue
        details = try_interpreter(path)
        try:
            shapes = fbs_shapes(path)
            print(f"  flatbuffer subgraph-0 tensors:")
            for ttag, tname, tshape in shapes:
                print(f"    [{ttag}] {tname} shape={tshape}")
            evidence[name] = ("shapes", shapes)
        except Exception as e:  # noqa: BLE001 — fall back to strings
            print(f"  flatbuffer parse failed ({e}).")
            shapes = None
        if details:
            print(f"  interpreter inputs: {details[0]}")
            print(f"  interpreter outputs: {details[1]}")
            evidence[name] = ("interpreter", details)
        elif shapes is None:
            text_hits = string_scan(path, TEXT_MARKERS)
            image_hits = string_scan(path, IMAGE_MARKERS)
            print(f"  string scan:")
            print(f"    text markers: "
                  f"{[m for m, h in text_hits.items() if h]}")
            print(f"    image markers: "
                  f"{[m for m, h in image_hits.items() if h]}")
            evidence[name] = ("strings",
                              sum(text_hits.values()),
                              sum(image_hits.values()))
    if not ok_all:
        return 1

    # Verdict prefers decoded input shapes; falls back to file sizes
    # (ViT image encoders are several-x larger than text encoders).
    def looks_like_image(shapes) -> bool:
        # NHWC [1,224,224,3] or NCHW [1,3,256,256].
        return any(tag == "in" and len(shape) == 4 and 3 in shape
                   for tag, _, shape in shapes)

    def looks_like_text(shapes) -> bool:
        return any(tag == "in" and (len(shape) == 2 or shape[-1] != 3)
                   for tag, _, shape in shapes)

    shaped = {n: ev[1] for n, ev in evidence.items() if ev[0] == "shapes"}
    joint = [n for n, s in shaped.items()
             if looks_like_image(s) and looks_like_text(s)]
    image_file = next((n for n, s in shaped.items() if looks_like_image(s)),
                      None)
    text_file = next((n for n, s in shaped.items() if looks_like_text(s)
                      and n != image_file), None)
    if joint:
        print(f"\nVerdict (from tensor shapes): {joint[0]} is a JOINT "
              f"image+text model — one file serves both towers.")
    elif image_file and text_file:
        print(f"\nVerdict (from tensor shapes): {image_file} = IMAGE tower, "
              f"{text_file} = TEXT tower.")
    else:
        print("\nVerdict: inconclusive from shapes — run on device with a "
              "TFLite interpreter to confirm input details.")
    from fetch_models import valid_tokenizer
    tok_ok, tok_why = valid_tokenizer(args.models_dir)
    print(f"tokenizer vocab.json + merges.txt: {tok_why}")
    print("Device must still confirm via interpreter input shapes "
          "(image: [1,3,256,256]-like; text: [1,77]-like token ids) "
          "before FeatureExtractor wiring.")
    return 0 if ok_all and tok_ok else 1


if __name__ == "__main__":
    sys.exit(main())
