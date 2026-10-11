"""Stage 2b: PT2E dynamic-range -> litert_torch (Linux/Colab).

Documented flow for this litert_torch generation (dynamic int8 weights,
float activations — no calibration data, float I/O preserved for the Dart
loader):
  prepare (observers) -> calibrate (one sample run) -> convert_pt2e ->
  litert_torch.convert with QuantConfig.

Usage (Colab, after the pip cell + weight download cell):
  !python convert_litert_dr.py --source "{src}" \
      --out /content/clip_joint_b32_dr2.tflite
Exit 0 + byte count on success.
"""
import argparse
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    import torch
    import open_clip
    from export_joint_onnx import JointCLIP32, eot_of

    print("  loading torch float source ...")
    model, _, _ = open_clip.create_model_and_transforms(
        "ViT-B-32", pretrained=args.source)
    joint = JointCLIP32(model).eval()
    ids = open_clip.get_tokenizer("ViT-B-32")(["sunset over the ocean"])
    tok32 = ids.to(torch.int32)
    eot = torch.tensor([[eot_of(ids.tolist())]], dtype=torch.int32)
    img = torch.zeros(1, 3, 224, 224)
    sample = (img, tok32, eot)

    from torchao.quantization.pt2e.quantize_pt2e import (
        prepare_pt2e,
        convert_pt2e,
    )
    from litert_torch.quantize.pt2e_quantizer import (
        get_symmetric_quantization_config,
        PT2EQuantizer,
    )
    from litert_torch.quantize.quant_config import QuantConfig
    import litert_torch

    print("  PT2E prepare (dynamic per-channel int8 weights) ...")
    quantizer = PT2EQuantizer().set_global(
        get_symmetric_quantization_config(is_per_channel=True,
                                          is_dynamic=True)
    )
    exported = torch.export.export(joint, sample).module()
    prepared = prepare_pt2e(exported, quantizer)
    prepared(*sample)
    quantized = convert_pt2e(prepared, fold_quantize=False)

    print("  litert_torch.convert ...")
    edge = litert_torch.convert(
        quantized, sample,
        quant_config=QuantConfig(pt2e_quantizer=quantizer))
    edge.export(args.out)
    size = os.path.getsize(args.out)
    print(f"  wrote {os.path.basename(args.out)} ({size/1e6:.1f}MB)")
    print("  NEXT: tools/validate_clip.py --tflite "
          f"{args.out} --source {args.source}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
