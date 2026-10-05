"""Final build gate: fail the build, rather than the first job, when the image is inconsistent.

Checks, in this order:
  * PyTorch and its CUDA version match the ABI in the Nunchaku wheel's version tag,
    and the compiled Nunchaku extension imports (skipped when Nunchaku is not installed);
  * no second virtual environment exists next to /opt/venv;
  * --models FILE: every file in a `sha256sum` manifest is present and unaltered;
  * --qwenvl REPO FILE: a Qwen GGUF model and its vision projector are where the
    installed ComfyUI-QwenVL looks for them.
"""
import argparse
import importlib.metadata as metadata
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--models", help="sha256sum manifest of the bundled models")
parser.add_argument("--qwenvl", nargs=2, metavar=("REPO", "FILE"), action="append", default=[],
                    help="ComfyUI-QwenVL catalogue entry and the GGUF file it must find")
args = parser.parse_args()

import torch  # noqa: E402  (after argument parsing so --help stays fast)

summary = [f"PyTorch {torch.__version__}", f"CUDA {torch.version.cuda}"]

try:
    wheel = metadata.version("nunchaku")
except metadata.PackageNotFoundError:
    wheel = None
if wheel:
    match = re.search(r"\+cu([\d.]+)torch([\d.]+)$", wheel)
    if not match:
        raise SystemExit(f"Cannot read the CUDA/PyTorch ABI from nunchaku {wheel}")
    cuda, torch_series = match.groups()
    if torch.version.cuda != cuda or not torch.__version__.startswith(torch_series + "."):
        raise SystemExit(
            f"nunchaku {wheel} needs PyTorch {torch_series}.x with CUDA {cuda}, "
            f"but the image has PyTorch {torch.__version__} with CUDA {torch.version.cuda}"
        )
    import nunchaku  # noqa: F401,E402  (the compiled extension must load against this PyTorch)
    summary.append(f"nunchaku {wheel}")

for venv in ("/comfyui/.venv", "/comfyui/venv"):
    if Path(venv).exists():
        raise SystemExit(f"{venv} exists: dependencies were installed outside /opt/venv")

if args.models:
    subprocess.run(["sha256sum", "--check", "--quiet", args.models], check=True)
    summary.append("models verified")

if args.qwenvl:
    qwenvl = Path("/comfyui/custom_nodes/ComfyUI-QwenVL")
    catalog = json.loads((qwenvl / "gguf_models.json").read_text())
    for repo, model_file in args.qwenvl:
        entry = catalog["qwenVL_model"][repo]
        qwen_dir = Path("/comfyui/models", catalog["base_dir"], entry["author"], entry["repo_name"])
        for name in (model_file, entry["mmproj_file"]):
            if not (qwen_dir / name).is_file():
                raise SystemExit(f"{qwen_dir / name} is missing: ComfyUI-QwenVL would download it at runtime")
    summary.append("Qwen paths verified")

print("verify-image OK: " + ", ".join(summary))
