"""Ranking-agreement gate for the converted joint TFLite (Stage 2 exit).

Compares the INT8 TFLite against the float PyTorch source on a probe set
of real photos x captions:
  * per-tower cosine drift (tflite vs torch embeddings)
  * image->caption top-1 agreement over the cross-similarity matrix

PASS: top-1 agreement >= 7/8 AND mean abs drift < 0.05.
Dynamic-range int8 on retrieval towers is usually near-exact; anything
worse means the conversion damaged the space — do not ship.

No torchvision anywhere (hand-rolled PIL preprocess): torchvision is
version-coupled to torch and breaks across environments.

Usage:
  python tools/validate_clip.py --tflite clip_joint_b32_int8.tflite
      [--source open_clip_pytorch_model.bin]
Exit 0 on PASS.
"""
import argparse
import math
import os
import sys
import urllib.request

import numpy as np

CAPTIONS = [
    "a photo of a cat",
    "sunset over the ocean",
    "receipt from a grocery store",
    "a dog running on grass",
    "city street at night",
    "birthday cake with candles",
    "mountain lake reflection",
    "busy market stall with fruit",
]

# Real photos (deterministic seeds) so text<->image similarities are real.
IMAGE_URLS = [
    f"https://picsum.photos/seed/querypic{i}/400/400" for i in range(8)
]

CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)


def clip_preprocess(pil_img):
    """Center-crop, resize 224, normalize — mirrors ClipVision.preprocess."""
    from PIL import Image

    w, h = pil_img.size
    side = min(w, h)
    img = pil_img.crop(((w - side) // 2, (h - side) // 2,
                        (w + side) // 2, (h + side) // 2))
    img = img.resize((224, 224), Image.BICUBIC).convert("RGB")
    arr = np.asarray(img).astype(np.float32) / 255.0
    arr = (arr - CLIP_MEAN) / CLIP_STD
    return arr.transpose(2, 0, 1)[None, :, :, :]  # [1,3,224,224]


def fetch_images(cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    paths = []
    for i, url in enumerate(IMAGE_URLS):
        dest = os.path.join(cache_dir, f"probe_{i}.jpg")
        if not os.path.exists(dest):
            req = urllib.request.Request(url,
                                         headers={"User-Agent": "QueryPic/1.0"})
            with urllib.request.urlopen(req, timeout=60) as r, \
                    open(dest, "wb") as f:
                f.write(r.read())
        paths.append(dest)
    return paths


def norm(v):
    v = v.astype(np.float64)
    return v / (np.linalg.norm(v) + 1e-12)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tflite", required=True)
    ap.add_argument("--source", default=None)
    ap.add_argument("--cache", default="/tmp/clip_probes")
    args = ap.parse_args()

    import torch
    import open_clip
    from PIL import Image

    print("  loading torch float source ...")
    if args.source is not None:
        model, _, _ = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained=args.source)
    else:
        model, _, _ = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained="laion2b_s34b_b79k")
    model.eval()
    tok = open_clip.get_tokenizer("ViT-B-32")

    print("  loading tflite candidate ...")
    # Interpreter order matters: TF first (full type support incl. int64
    # inputs + ARG_MAX). ai-edge-litert's Python build rejects int64
    # ("Unknown input type: 4") — an environment quirk, NOT a model flaw
    # (Android tflite_flutter runs int64 fine). Fall through on RUN failure,
    # not just on missing imports (2026-10-09).
    interp = None
    problems = []
    try:
        import tensorflow as tf
        interp = tf.lite.Interpreter(model_path=args.tflite)
        interp.allocate_tensors()
        print("  interpreter: tensorflow")
    except Exception as e:  # noqa: BLE001 — try the next runtime
        problems.append(f"tensorflow: {str(e)[:160]}")
        interp = None
    if interp is None:
        try:
            from tflite_runtime.interpreter import Interpreter as TRInterp
            interp = TRInterp(model_path=args.tflite)
            interp.allocate_tensors()
            print("  interpreter: tflite_runtime")
        except Exception as e:  # noqa: BLE001
            problems.append(f"tflite_runtime: {str(e)[:160]}")
            interp = None
    if interp is None:
        try:
            from ai_edge_litert.interpreter import Interpreter as EdgeInterp
            interp = EdgeInterp(model_path=args.tflite)
            interp.allocate_tensors()
            print("  interpreter: ai_edge_litert")
        except Exception as e:  # noqa: BLE001
            problems.append(f"ai_edge_litert: {str(e)[:160]}")
            interp = None
    if interp is None:
        print("FAIL: no interpreter could run the file:")
        for p in problems:
            print(f"    {p}")
        return 1
    in_det = interp.get_input_details()
    out_det = interp.get_output_details()
    print(f"  tflite in: {[(d['shape'].tolist(), str(d['dtype'])) for d in in_det]}")
    print(f"  tflite out: {[(d['shape'].tolist(), str(d['dtype'])) for d in out_det]}")
    # Find inputs by shape. NOTE: onnx2tf transposes the image tower to
    # NHWC ([1,224,224,3]) — TFLite convention — while the Dart frontend
    # emits NCHW, so both the validator and the loader transpose to NHWC.
    # (Int64-free graph: TFLite rejects int64 inputs and ArgMax outputs.)
    img_idx = txt_idx = eot_idx = None
    img_nhwc = False
    for d in in_det:
        s = list(d["shape"])
        if len(s) == 4 and (s[1] == 3 or s[3] == 3):
            img_idx = d["index"]
            img_nhwc = s[3] == 3
        elif len(s) == 2 and s[1] == 77:
            txt_idx = d["index"]
        elif (len(s) == 1 and s[0] == 1) or len(s) == 0:
            eot_idx = d["index"]
    outs512 = [d["index"] for d in out_det
               if len(list(d["shape"])) == 2 and list(d["shape"])[1] == 512]
    assert img_idx is not None and txt_idx is not None, "input layout moved!"
    assert eot_idx is not None, "eot input missing!"
    assert len(outs512) == 2, f"expected two 512-d heads, got {len(outs512)}"

    def tflite_embed(image_np, ids_np, eot):
        img = image_np.transpose(0, 2, 3, 1) if img_nhwc else image_np
        interp.set_tensor(img_idx, img.astype(np.float32))
        txt_dtype = [d for d in in_det if d["index"] == txt_idx][0]["dtype"]
        interp.set_tensor(txt_idx, ids_np.astype(
            np.int64 if "int64" in str(txt_dtype) else np.int32))
        interp.set_tensor(eot_idx, np.array([eot], dtype=np.int32))
        interp.invoke()
        return (interp.get_tensor(outs512[0])[0],
                interp.get_tensor(outs512[1])[0])

    print("  fetching probe photos ...")
    paths = fetch_images(args.cache)
    images = [clip_preprocess(Image.open(p)) for p in paths]
    with torch.no_grad():
        torch_txt = [
            model.encode_text(tok([c]), normalize=False)[0].numpy()
            for c in CAPTIONS
        ]
        torch_img = [
            model.encode_image(
                torch.from_numpy(im), normalize=False)[0].numpy()
            for im in images
        ]
    lite_txt, lite_img = [], []
    for c, im in zip(CAPTIONS, images):
        ids = tok([c]).numpy()
        row = ids[0].tolist()
        eot = row.index(49407, 1)  # first EOT at index>=1 (never in words)
        a, b = tflite_embed(im, ids, eot)
        lite_img.append(a)
        lite_txt.append(b)

    # Per-tower drift (nan-robust: report NaN fraction separately —
    # a NaN mean hides whether one tower or everything broke).
    drifts = []
    nan_towers = 0
    total_towers = 0
    for a, b in list(zip(torch_txt, lite_txt)) + list(zip(torch_img,
                                                          lite_img)):
        total_towers += 1
        na, nb = norm(np.asarray(a, dtype=np.float64)), norm(
            np.asarray(b, dtype=np.float64))
        if not np.all(np.isfinite(nb)):
            nan_towers += 1
            continue
        drifts.append(float(np.abs(na - nb).mean()))
    mean_drift = sum(drifts) / len(drifts) if drifts else float("nan")

    # Cross-matrix top-1 agreement (image -> caption).
    agree = 0
    for i in range(8):
        qt = [float(norm(torch_img[i]) @ norm(t)) for t in torch_txt]
        ql = [float(norm(np.asarray(lite_img[i])) @ norm(t))
              for t in lite_txt]
        if int(np.argmax(qt)) == int(np.argmax(ql)):
            agree += 1
    print(f"  mean abs drift: {mean_drift:.4f} (gate < 0.05)")
    print(f"  non-finite towers: {nan_towers}/{total_towers}")
    print(f"  top-1 agreement: {agree}/8 (gate >= 7)")
    if nan_towers == 0 and agree >= 7 and mean_drift < 0.05:
        print("PASS: int8 ranks like float — safe to ship to the phone")
        return 0
    print("FAIL: conversion damaged the space — do not ship")
    return 1


if __name__ == "__main__":
    sys.exit(main())
