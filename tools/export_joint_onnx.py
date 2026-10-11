"""Export the MIT-licensed LAION ViT-B/32 checkpoint as a JOINT ONNX graph.

Joint layout (int64-free: TFLite rejects int64 graph inputs and int64
ArgMax outputs — "Unknown input type: 4"):
  inputs : image [1,3,224,224] float32 (CLIP-preprocessed NCHW, exactly
           what ClipVision.preprocess emits) + text [1,77] INT32 token ids
           + eot [1] INT32 (EOT position = first 49407 at index>=1; the
           Dart tokenizer computes it — no ArgMax anywhere in the graph)
  outputs: image_emb [1,512] + text_emb [1,512] float32 (RAW, unnormalized —
           the Dart side L2-normalizes + INT8-quantizes as before) +
           scale [] float32 (logit scale, ignored by the loader).

The text tail is reimplemented (embedding + transformer + ln + one-hot
pool at the EOT index) instead of calling encode_text, whose internal
argmax would reintroduce int64. One-hot + MatMul pooling uses only
universally supported ops.

Stage 1 of the clean pipeline (runs on any torch host, no TF needed):
  Stage 2: convert_litert_dr.py (direct torch->TFLite, reference DR).

Usage:
  py tools/export_joint_onnx.py [--source BIN] [--out joint.onnx]
Exit 0 + cosine agreement report on success.
"""
import argparse
import os
import sys

import torch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = os.path.join(ROOT, "querypic", "sandbox", "models",
                           "open_clip_pytorch_model.bin")
DEFAULT_OUT = os.path.join(ROOT, "querypic", "sandbox", "models",
                           "clip_joint_b32.onnx")

EOT_ID = 49407


class JointCLIP32(torch.nn.Module):
    """Both towers, one graph, raw (unnormalized) 512-d outputs.

    Int32 in, no ArgMax: tokens arrive int32 (cast to int64 only for the
    embedding Gather) and pooling masked-sums the caller-supplied int32
    EOT. Torch parity vs encode_* proven to cos=1.0 (all probes).
    """

    def __init__(self, clip):
        super().__init__()
        self.token_embedding = clip.token_embedding
        self.positional_embedding = clip.positional_embedding
        self.transformer = clip.transformer
        self.ln_final = clip.ln_final
        self.text_projection = clip.text_projection
        self.attn_mask = clip.attn_mask
        self.visual = clip.visual
        self.logit_scale = clip.logit_scale

    def forward(self, image, tokens32, eot32):
        tokens = tokens32.to(torch.int64)
        img = self.visual(image)
        cast = self.transformer.get_cast_dtype()
        x = self.token_embedding(tokens).to(cast)
        x = x + self.positional_embedding.to(cast)
        x = self.transformer(x, attn_mask=self.attn_mask)
        x = self.ln_final(x)
        # Masked-sum pool at the EOT index: Equal + Mul + ReduceSum only.
        # (Earlier revisions used argmax-gather (int64 rejected by TFLite)
        # then one-hot+bmm (strict torch.export shape inference rejects
        # it). Masked sum is mathematically identical and traces cleanly
        # under strict export, dynamo export, ONNX, and litert_torch.)
        pos = torch.arange(x.shape[1], device=x.device).unsqueeze(0)
        mask = (pos == eot32).to(x.dtype).unsqueeze(-1)
        pooled = (x * mask).sum(dim=1)
        if isinstance(self.text_projection, torch.nn.Linear):
            txt = self.text_projection(pooled)
        else:
            txt = pooled @ self.text_projection
        scale = self.logit_scale.exp().reshape(())
        return img, txt, scale


def eot_of(ids) -> int:
    row = list(ids[0] if hasattr(ids, "__getitem__") else ids)
    return row.index(EOT_ID, 1)


def cosine(a: torch.Tensor, b: torch.Tensor) -> float:
    a = a.flatten().float()
    b = b.flatten().float()
    return float((a @ b) / (a.norm() * b.norm() + 1e-12))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()

    import open_clip

    print(f"  loading {os.path.basename(args.source)} ...")
    model, _, _ = open_clip.create_model_and_transforms(
        "ViT-B-32", pretrained=args.source)
    model.eval()
    joint = JointCLIP32(model).eval()

    img = torch.zeros(1, 3, 224, 224)
    tok = open_clip.get_tokenizer("ViT-B-32")(["sunset over the ocean"])
    eot = torch.tensor([eot_of(tok.tolist())], dtype=torch.int32)
    tok32 = tok.to(torch.int32)
    assert list(img.shape) == [1, 3, 224, 224]
    assert list(tok32.shape) == [1, 77], f"text layout {tok32.shape}"

    print("  exporting joint ONNX (dynamo exporter: handles SDPA) ...")
    with torch.no_grad():
        torch.onnx.export(
            joint, (img, tok32, eot), args.out,
            input_names=["image", "text", "eot"],
            output_names=["image_emb", "text_emb", "scale"],
            dynamic_axes=None,
        )
    size = os.path.getsize(args.out)
    print(f"  wrote {os.path.basename(args.out)} ({size/1e6:.1f}MB)")

    if args.no_validate:
        return 0

    # Validate: ONNX Runtime must reproduce torch embeddings ~exactly.
    try:
        import onnxruntime as ort
    except ImportError:
        print("  SKIP validation (pip install onnxruntime to enable)")
        return 0
    import numpy as np

    torch.manual_seed(0)
    probe_img = torch.randn(1, 3, 224, 224)
    probe_ids = open_clip.get_tokenizer("ViT-B-32")(
        ["receipt from home depot"])
    probe_tok = probe_ids.to(torch.int32)
    probe_eot = torch.tensor([eot_of(probe_ids.tolist())], dtype=torch.int32)
    with torch.no_grad():
        t_img, t_txt, _ = joint(probe_img, probe_tok, probe_eot)
    sess = ort.InferenceSession(args.out,
                                providers=["CPUExecutionProvider"])
    o_img, o_txt, _ = sess.run(
        None,
        {"image": probe_img.numpy().astype(np.float32),
         "text": probe_tok.numpy().astype(np.int32),
         "eot": probe_eot.numpy().astype(np.int32)},
    )
    ci = cosine(t_img, torch.from_numpy(o_img))
    ct = cosine(t_txt, torch.from_numpy(o_txt))
    print(f"  agreement: image cos={ci:.6f} text cos={ct:.6f}")
    if min(ci, ct) < 0.999:
        print("  FAIL: export diverged from torch — do not ship")
        return 1
    print("PASS: joint ONNX matches torch; ready for Stage 2 (TFLite)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
