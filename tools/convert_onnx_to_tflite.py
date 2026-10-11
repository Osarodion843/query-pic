"""Stage 2 (RUN ON LINUX/COLAB — needs TF + onnx2tf, no Windows wheels).

Converts Stage 1's joint ONNX (tools/export_joint_onnx.py) into the joint
INT8 TFLite the Flutter loader runs on-device:
  inputs : image [1,3,224,224] float32 + text [1,77] int64
  outputs: image_emb [1,512] + text_emb [1,512] + scale [] (all float32;
           the Dart side normalizes + INT8-quantizes as before)

Why INT8 dynamic-range (weights-only):
  ~4x smaller (~150MB vs 605MB fp32), 2-3x faster CPU via quantized XNNPACK
  kernels, and — critically for itel S666LN, where the fp32 MobileCLIP
  graph segfaults mid-inference — an entirely different kernel path.
  Retrieval accuracy cost is typically <2% Recall@1; tools/validate_clip.py
  proves ranking agreement before anything ships.

Colab recipe (CPU runtime is fine):
  !pip install -q onnx2tf onnxruntime tensorflow-cpu
  !python tools/convert_onnx_to_tflite.py --onnx <path> --out <path>
  then tools/validate_clip.py --tflite <path> (needs onnxruntime +
  tflite_runtime or ai-edge-litert interpreter)

Usage:
  python tools/convert_onnx_to_tflite.py [--onnx IN] [--out OUT]
Exit 0 + size report on success.
"""
import argparse
import os
import sys

DEFAULT_OUT = "clip_joint_b32_int8.tflite"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--quantize", action="store_true", default=True)
    ap.add_argument("--no-quantize", dest="quantize", action="store_false")
    args = ap.parse_args()

    try:
        import onnx2tf
    except ImportError:
        print("FAIL: pip install onnx2tf (Linux only — no Windows wheels)")
        return 1

    onnx_path = args.onnx
    if onnx_path is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        onnx_path = os.path.join(root, "querypic", "sandbox", "models",
                                 "clip_joint_b32.onnx")
    out_dir = os.path.dirname(args.out) if args.out else None
    if out_dir is None:
        out_dir = os.path.dirname(onnx_path) or "."
    want_name = os.path.basename(args.out) if args.out else DEFAULT_OUT
    if not args.quantize:
        want_name = want_name.replace("_int8", "_float32")
    before = set(os.listdir(out_dir))
    print(f"  converting {os.path.basename(onnx_path)} ...")
    # Dynamic-range (weights-only) int8: activations stay float, so no
    # calibration dataset is needed and the loader's float I/O is kept.
    # NOTE: onnx2tf only emits the dynamic-range file when
    # output_dynamic_range_quantized_tflite=True — quant_type alone just
    # changes the (always-written) float16 variant. Missing this flag is
    # why the first run produced float32+float16 only (2026-10-09).
    onnx2tf.convert(
        input_onnx_file_path=onnx_path,
        output_folder_path=out_dir,
        output_integer_quantized_tflite=False,
        output_dynamic_range_quantized_tflite=args.quantize,
        quant_type="per-channel" if args.quantize else "float32",
    )
    after = sorted(set(os.listdir(out_dir)) - before)
    fresh = [f for f in after if f.endswith(".tflite")]
    print(f"  emitted: {fresh or after}")
    # Copy the chosen artifact to the canonical name so the next stage
    # (validate_clip.py --tflite <it>) never hits a missing file.
    src_name = None
    for f in fresh:
        if args.quantize and "dynamic" in f and "range" in f:
            src_name = f
            break
    if src_name is None:
        for f in fresh:
            if "float32" in f:
                src_name = f
                break
    if src_name is None and fresh:
        src_name = fresh[0]
    if src_name is None:
        print("  FAIL: no .tflite emitted — see onnx2tf log above")
        return 1
    import shutil
    dest = os.path.join(out_dir, want_name)
    shutil.copy(os.path.join(out_dir, src_name), dest)
    size = os.path.getsize(dest)
    print(f"  canonical: {want_name} ({size/1e6:.1f}MB, from {src_name})")
    print("  NEXT: tools/validate_clip.py --tflite "
          f"{dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
