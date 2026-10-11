"""Reference dynamic-range via ai_edge_quantizer on a FLOAT32 TFLite.

Why this file exists: onnx2tf's and litert_torch's dynamic-range passes
quantize the token-embedding table ASYMMETRIC (nonzero zero-point), and
every TFLite embedding_lookup kernel — Colab, Android, everywhere —
rejects it (`zero_point == 0 was not true`, node 758). Google's reference
quantizer (TFLiteConverter heritage) emits SYMMETRIC weight tables, which
the kernel accepts. Same float I/O, same ~4x size win.

Usage (Linux/Colab):
  !python quantize_aeq.py --in /content/clip_joint_b32_float32.tflite \
      --out /content/clip_joint_b32_aeq.tflite
Exit 0 + byte count on success.
"""
import argparse
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    from ai_edge_quantizer import quantizer, recipe

    q = quantizer.Quantizer(args.src)
    q.update_quantization_recipe(recipe.dynamic_wi8_afp32())
    q.quantize()
    q.save(args.out)
    size = os.path.getsize(args.out)
    print(f"  wrote {os.path.basename(args.out)} ({size/1e6:.1f}MB)")
    print("  NEXT: tools/validate_clip.py --tflite "
          f"{args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
