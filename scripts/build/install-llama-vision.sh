#!/usr/bin/env bash
# install-llama-vision: install the CUDA llama-cpp-python wheel that ComfyUI-QwenVL
# needs for Qwen-VL GGUF models.
#
# Environment:
#   LLAMA_CPP_WHEEL_URL     direct download URL of the wheel (required)
#   LLAMA_CPP_WHEEL_SHA256  expected SHA256 of the wheel (required)
#   LLAMA_WHEEL_CACHE       folder that keeps downloaded wheels (default /opt/wheels)
set -euo pipefail

: "${LLAMA_CPP_WHEEL_URL:?LLAMA_CPP_WHEEL_URL is required}"
: "${LLAMA_CPP_WHEEL_SHA256:?LLAMA_CPP_WHEEL_SHA256 is required}"
cache="${LLAMA_WHEEL_CACHE:-/opt/wheels}"

# Release assets encode "+" as "%2B"; pip needs the real file name.
wheel="${cache}/$(basename "${LLAMA_CPP_WHEEL_URL}" | sed 's/%2[Bb]/+/g')"
mkdir -p "$cache"

if ! echo "${LLAMA_CPP_WHEEL_SHA256}  ${wheel}" | sha256sum --check --status 2>/dev/null; then
  echo "Downloading $(basename "$wheel")"
  curl -fL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
    "${LLAMA_CPP_WHEEL_URL}" -o "$wheel"
  echo "${LLAMA_CPP_WHEEL_SHA256}  ${wheel}" | sha256sum --check -
else
  echo "Using cached wheel: $(basename "$wheel")"
fi

/opt/venv/bin/python -m pip install --no-cache-dir --force-reinstall "$wheel"

# Verify the vision chat handlers without importing llama_cpp: importing it
# would load CUDA, which is not available while the image is built.
/opt/venv/bin/python - <<'PY'
import pathlib
import site

target = None
for sp in site.getsitepackages():
    cand = pathlib.Path(sp) / "llama_cpp" / "llama_chat_format.py"
    if cand.exists():
        target = cand
        break

if not target:
    raise SystemExit("Could not find llama_cpp/llama_chat_format.py in site-packages")

txt = target.read_text(encoding="utf-8", errors="ignore")
needed = ["Qwen3VLChatHandler", "Qwen25VLChatHandler"]
missing = [n for n in needed if n not in txt]
if missing:
    raise SystemExit(f"Missing handlers in {target}: {missing}")

print(f"OK: found {needed} in {target} (no CUDA import during build)")
PY
