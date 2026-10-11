"""Build tools/colab_int8.ipynb: the one-click Stage-2 notebook.

Proven path (2026-10-10):
  export (masked-sum ONNX, cos=1.0) -> onnx2tf float32 (8/8 gate) ->
  ai_edge_quantizer dynamic_wi8_afp32 (SYMMETRIC tables — the embedding
  kernel rejects every other DR attempt) -> validate gate.
Dead ends removed: onnx2tf DR (asymmetric table), litert DR (same),
float16 (conv rejects fp16 input), onnx-tf (incompatible with modern onnx).

All scripts embedded (%%writefile): no git checkout, no uploads. Colab
pulls the 605MB MIT source from HF itself, user downloads one ~150MB
.tflite on PASS.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(name):
    with open(os.path.join(ROOT, "tools", name), encoding="utf-8") as f:
        return f.read()


def md(source):
    return {"cell_type": "markdown", "metadata": {},
            "source": source}


def code(source):
    return {"cell_type": "code", "execution_count": None, "metadata": {},
            "outputs": [], "source": source}


cells = [
    md([
        "# QueryPic Stage 2: clean joint INT8 CLIP\n",
        "\n",
        "Converts the MIT-licensed LAION ViT-B/32 checkpoint into the joint\n",
        "INT8 `.tflite` the app runs on-device. **Start from a FACTORY-RESET\n",
        "runtime** (Runtime menu) so no stale packages linger, then Run all.\n",
        "**CPU runtime is fine.** ~30-60 min wall time.\n",
        "\n",
        "**How to run:** factory reset, then Runtime > Run all. Download\n",
        "`/content/clip_joint_b32_aeq.tflite` from the Files pane when the\n",
        "gate prints PASS.\n",
    ]),
    # ONE joint pip transaction (numpy pinned: native bindings segfault
    # across numpy ABIs; onnx2tf wants the 2.2 line).
    code(["%pip install -q --upgrade torch open_clip_torch onnx onnxruntime "
          "onnxscript onnx2tf tensorflow-cpu huggingface_hub Pillow "
          "ai-edge-torch torchao \"numpy==2.2.6\""]),
    code([
        "# Smoke test: versions must import TOGETHER. Red here = stop and\n",
        "# report; running on is how earlier sessions burned hours.\n",
        "!python -c \"import torch, open_clip; "
        "print(torch.__version__, 'ok')\"",
    ]),
    code(["%%writefile export_joint_onnx.py\n", read("export_joint_onnx.py")]),
    code(["%%writefile convert_onnx_to_tflite.py\n",
          read("convert_onnx_to_tflite.py")]),
    code(["%%writefile quantize_aeq.py\n", read("quantize_aeq.py")]),
    code(["%%writefile validate_clip.py\n", read("validate_clip.py")]),
    code([
        "from huggingface_hub import hf_hub_download\n",
        "src = hf_hub_download('laion/CLIP-ViT-B-32-laion2B-s34B-b79K',\n",
        "                      'open_clip_pytorch_model.bin')\n",
        "print('source:', src)\n",
    ]),
    code([
        "!python export_joint_onnx.py --source \"{src}\" "
        "--out /content/clip_joint_b32.onnx",
    ]),
    code([
        "# Float32 base (faithful lowering; --no-quantize skips onnx2tf's "
        "broken DR pass).\n",
        "!python convert_onnx_to_tflite.py --onnx /content/clip_joint_b32.onnx "
        "--out /content/clip_joint_b32_f32.tflite --no-quantize\n",
        "!ls -la /content/*.tflite",
    ]),
    code([
        "# Reference dynamic-range (symmetric tables). Shippable candidate.\n",
        "!python quantize_aeq.py --in /content/clip_joint_b32_float32.tflite "
        "--out /content/clip_joint_b32_aeq.tflite\n",
        "!ls -la /content/*.tflite",
    ]),
    code([
        "!python validate_clip.py --tflite /content/clip_joint_b32_aeq.tflite "
        "--source \"{src}\"",
    ]),
    md([
        "## Back on the PC (only if the gate prints PASS)\n",
        "\n",
        "1. Download **`clip_joint_b32_aeq.tflite`** from Colab's Files pane.\n",
        "2. Push it to the phone (renamed to the name the app expects):\n",
        "\n",
        "```\n",
        "adb push clip_joint_b32_aeq.tflite "
        "/sdcard/Android/data/com.example.querypic/files/models/"
        "clip_joint_b32_int8.tflite\n",
        "```\n",
        "(If push complains about ownership, push to `/data/local/tmp/` "
        "then copy it into the app's `app_flutter/models/` dir.)\n",
        "\n",
        "3. In QueryPic: Settings > turn CLIP **off and on once** (resets the\n",
        "   crash fuse), fully close the app, reopen.\n",
        "4. Settings > Model status — paste the `clip:` lines back.\n",
        "   Expect `joint loaded`, then a full re-index with real vectors.\n",
    ]),
]

nb = {"nbformat": 4, "nbformat_minor": 5,
      "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"},
                   "language_info": {"name": "python"}},
      "cells": cells}
out = os.path.join(ROOT, "tools", "colab_int8.ipynb")
with open(out, "w", encoding="utf-8") as f:
    json.dump(nb, f, indent=1)
print("wrote", out, len(cells), "cells")
