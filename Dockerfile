# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
ARG ENHANCE_CORE_IMAGE=final-enhance-core

# Build helpers live in scripts/build/ and are bind-mounted into the RUN steps that
# use them, so they are not part of the image and a changed helper only rebuilds
# the steps that mount it.

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments are declared right before their first use. A changed value then
# only rebuilds the layers after that point: images that differ in the ComfyUI
# version, for example, still share the Python and PyTorch layers.

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools.
# Recommended packages are kept on purpose: python3-pip pulls in build-essential
# and python3-dev, which custom-node requirements without wheels (e.g. insightface)
# need to compile. The cleanup runs in the same layer so it actually shrinks it.
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    python3-pip \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install a pinned uv using the official installer and create an isolated venv
ARG UV_VERSION=0.12.23
RUN wget -qO- "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands.
# VIRTUAL_ENV must be set, not only PATH: without it comfy-cli treats /opt/venv as
# an isolated tool environment, creates a second venv at /comfyui/.venv and installs
# PyTorch, ComfyUI's requirements and every registry custom node's requirements
# there, while the entrypoint runs /opt/venv/bin/python.
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
# Keep pip/uv download caches out of the image layers
ENV PIP_NO_CACHE_DIR=1 \
    UV_NO_CACHE=1

# Install comfy-cli + dependencies needed by it to install ComfyUI
ARG COMFY_CLI_VERSION=1.22.0
RUN uv pip install "comfy-cli==${COMFY_CLI_VERSION}" pip setuptools wheel

# Install the requested PyTorch build first (for newer CUDA versions). comfy-cli is
# then told to skip its own PyTorch install, so the image does not carry a second,
# replaced PyTorch/CUDA stack in an earlier layer.
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL
ARG PYTORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCHAUDIO_VERSION
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      if [ -n "$PYTORCH_VERSION" ]; then \
        uv pip install \
          "torch==${PYTORCH_VERSION}" \
          "torchvision==${TORCHVISION_VERSION}" \
          "torchaudio==${TORCHAUDIO_VERSION}" \
          --index-url "${PYTORCH_INDEX_URL}"; \
      else \
        uv pip install torch torchvision torchaudio --index-url "${PYTORCH_INDEX_URL}"; \
      fi; \
    fi

# Optional version lock. Every pip and uv installation from here on, including the
# ones comfy-cli and the custom-node installers run, may only choose the versions
# listed in this file. The default file is empty; an image with a recorded package
# list passes its own (see constraints/).
ARG PIP_CONSTRAINTS_FILE=constraints/none.txt
COPY ${PIP_CONSTRAINTS_FILE} /opt/pip-constraints.txt
ENV PIP_CONSTRAINT=/opt/pip-constraints.txt \
    UV_CONSTRAINT=/opt/pip-constraints.txt

# Install ComfyUI
ARG COMFYUI_VERSION=0.38.0
ARG CUDA_VERSION_FOR_COMFY
RUN set -eu; \
    SKIP_TORCH=""; \
    if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then SKIP_TORCH="--skip-torch-or-directml"; fi; \
    if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia ${SKIP_TORCH}; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia ${SKIP_TORCH}; \
    fi; \
    if [ -e /comfyui/.venv ] || [ -e /comfyui/venv ]; then \
      echo "comfy-cli created a workspace venv instead of using /opt/venv" >&2; exit 1; \
    fi; \
    /opt/venv/bin/python -c "import torch, torchvision, torchaudio; print('PyTorch', torch.__version__, 'CUDA', torch.version.cuda)"

# Change working directory to ComfyUI
WORKDIR /comfyui

# Support for the network volume
COPY src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN --mount=type=bind,source=requirements.txt,target=/tmp/build/requirements.txt \
    uv pip install -r /tmp/build/requirements.txt

# Add script to install custom nodes
COPY --chmod=755 scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY --chmod=755 scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Keep runtime files in a tiny standalone stage so handler edits
# do not pull in heavy CUDA/ComfyUI layers when rebuilding thin overlays.
FROM scratch AS runtime-files
COPY --chmod=755 src/start.sh /start.sh
COPY src/network_volume.py /network_volume.py
COPY handler.py /handler.py
COPY test_input.json /test_input.json

# Stage 2: Download models
# Deliberately not built on `base`: the downloads only need wget, and keeping this
# stage independent means a ComfyUI or PyTorch change does not re-download models.
FROM ${BASE_IMAGE} AS downloader

RUN apt-get update \
 && apt-get install -y --no-install-recommends wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Retry downloads that fail with a temporary server error instead of failing a
# build that has already downloaded tens of gigabytes.
ENV WGETRC=/etc/wgetrc-downloads
RUN printf '%s\n' \
      'tries = 10' \
      'waitretry = 10' \
      'retry_connrefused = on' \
      'retry_on_http_error = 429,500,502,503,504' > "$WGETRC"

# Access tokens are BuildKit secrets, never build arguments, so they do not end up
# in the build cache, the image history or `docker buildx bake --print`:
#   --secret id=hf_token,env=HUGGINGFACE_ACCESS_TOKEN
#   --secret id=civitai_token,env=CIVITAI_API_TOKEN
# The Bake file passes both when the variables are set. Steps that read a token
# must not use `set -x`: it would print the token into the build log.
RUN printf '%s\n' \
      '#!/bin/sh' \
      '# Print the Hugging Face token, or explain how to pass it.' \
      'if [ -s /run/secrets/hf_token ]; then cat /run/secrets/hf_token; exit 0; fi' \
      'echo "This model is gated and needs a Hugging Face token. Set HUGGINGFACE_ACCESS_TOKEN and build with Bake, or pass --secret id=hf_token,env=HUGGINGFACE_ACCESS_TOKEN." >&2' \
      'exit 1' > /usr/local/bin/hf-token \
 && chmod +x /usr/local/bin/hf-token

ARG KREAMANIA_FP8_SHA256
# Set default model type if none is provided
ARG MODEL_TYPE=enhance
# Enhancement assets that no General Enhancement graph selects (about 19 GB:
# Nunchaku FLUX.1-dev FP4, Fluxmania Kreamania FP8, the Q8_0 Qwen projector).
# Set to "true" to bundle them anyway; Kreamania then needs the Civitai token.
ARG ENHANCE_EXTRA_MODELS=false

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront. The final stage copies each of these
# folders as its own layer; keep the three lists (here, the check at the end of
# this stage and the COPY lines in `final`) the same.
RUN mkdir -p \
    /comfyui/models/checkpoints \
    /comfyui/models/vae \
    /comfyui/models/unet \
    /comfyui/models/clip \
    /comfyui/models/clip_vision \
    /comfyui/models/text_encoders \
    /comfyui/models/diffusion_models \
    /comfyui/models/model_patches \
    /comfyui/models/controlnet \
    /comfyui/models/depthanything \
    /comfyui/models/ipadapter \
    /comfyui/models/loras \
    /comfyui/models/SEEDVR2 \
    /comfyui/models/upscale_models \
    /comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF \
    /comfyui/models/ultralytics/segm \
    /comfyui/models/ultralytics/bbox \
    /comfyui/models/sams

RUN --mount=type=secret,id=hf_token \
    if [ "$MODEL_TYPE" = "sd3" ]; then \
      wget -q --header="Authorization: Bearer $(hf-token)" -O models/checkpoints/sd3_medium_incl_clips_t5xxlfp8.safetensors https://huggingface.co/stabilityai/stable-diffusion-3-medium/resolve/main/sd3_medium_incl_clips_t5xxlfp8.safetensors; \
    fi

RUN --mount=type=secret,id=hf_token \
    if [ "$MODEL_TYPE" = "flux1-schnell" ]; then \
      wget -q --header="Authorization: Bearer $(hf-token)" -O models/unet/flux1-schnell.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors && \
      wget -q -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors && \
      wget -q -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors && \
      wget -q --header="Authorization: Bearer $(hf-token)" -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
    fi

RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ]; then \
      wget -nv -O /comfyui/models/checkpoints/epicrealism_naturalSinRC1VAE.safetensors \
        https://huggingface.co/philz1337x/epicrealism/resolve/main/epicrealism_naturalSinRC1VAE.safetensors; \
      wget -nv -O /comfyui/models/diffusion_models/svdq-fp4_r32-fluxmania-legacy.safetensors \
        https://huggingface.co/spooknik/Fluxmania-SVDQ/resolve/main/svdq-fp4_r32-fluxmania-legacy.safetensors; \
    fi

RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ] && [ "$ENHANCE_EXTRA_MODELS" = "true" ]; then \
      wget -nv -O /comfyui/models/diffusion_models/svdq-fp4_r32-flux.1-dev.safetensors \
        https://huggingface.co/nunchaku-ai/nunchaku-flux.1-dev/resolve/main/svdq-fp4_r32-flux.1-dev.safetensors; \
      wget -nv -O /comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf \
        https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf; \
    fi

# Fluxmania Kreamania (FP8) from Civitai
# Model page: https://civitai.com/models/778691/fluxmania
# Version: Kreamania (id=2106807), file: fluxmania_kreamania.safetensors
# The tokenized request is quiet (-q): wget would otherwise print the URL, token included.
RUN --mount=type=secret,id=civitai_token \
    set -eu; \
    if [ "$MODEL_TYPE" = "enhance" ] && [ "$ENHANCE_EXTRA_MODELS" = "true" ]; then \
      KREAMANIA_URL="https://civitai.com/api/download/models/2106807?type=Model&format=SafeTensor&size=full&fp=fp8"; \
      KREAMANIA_OUT="/comfyui/models/diffusion_models/fluxmania_kreamania.safetensors"; \
      CIVITAI_TOKEN="$(cat /run/secrets/civitai_token 2>/dev/null || true)"; \
      if [ -n "${CIVITAI_TOKEN}" ]; then \
        # Some Civitai redirects can reject the Authorization header on final storage URL.
        # Prefer token query param, then fall back to public URL for public files.
        if ! wget -q -O "${KREAMANIA_OUT}" "${KREAMANIA_URL}&token=${CIVITAI_TOKEN}"; then \
          echo "Tokenized Civitai download failed; retrying without token..." >&2; \
          wget -nv -O "${KREAMANIA_OUT}" "${KREAMANIA_URL}"; \
        fi; \
      else \
        wget -nv -O "${KREAMANIA_OUT}" "${KREAMANIA_URL}"; \
      fi; \
      if [ -n "${KREAMANIA_FP8_SHA256:-}" ]; then \
        echo "${KREAMANIA_FP8_SHA256}  ${KREAMANIA_OUT}" | sha256sum -c -; \
      else \
        echo "WARNING: KREAMANIA_FP8_SHA256 not set; checksum verification skipped for fluxmania_kreamania.safetensors" >&2; \
      fi; \
    fi

RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ]; then \
      wget -nv -O /comfyui/models/loras/detailSliderALT2.safetensors \
        https://huggingface.co/iamanaiart/flatloras/resolve/main/detailSliderALT2.safetensors; \
      wget -nv -O /comfyui/models/loras/boreal-flux-dev-lora-v04_1000_steps.safetensors \
        https://huggingface.co/kudzueye/Boreal/resolve/main/boreal-flux-dev-lora-v04_1000_steps.safetensors; \
      wget -nv -O /comfyui/models/loras/flux-RealismLora.safetensors \
        https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors; \
    fi

RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ]; then \
      wget -nv -O /comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf \
        https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q8_0.gguf; \
      wget -nv -O /comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf \
        https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-F16.gguf; \
    fi
RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ]; then \
      wget -nv -O /comfyui/models/upscale_models/1x-ReFocus-V3.pth \
        https://huggingface.co/notkenski/upscalers/resolve/main/1x-ReFocus-V3.pth; \
      wget -nv -O /comfyui/models/sams/sam_vit_b_01ec64.pth \
        https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth; \
      wget -nv -O /comfyui/models/ultralytics/bbox/face_yolov8m.pt \
        https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt; \
      wget -nv -O /comfyui/models/ultralytics/segm/person_yolov8m-seg.pt \
        https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt; \
      wget -nv -O /comfyui/models/ultralytics/segm/face_yolov8m-seg_60.pt \
        https://github.com/hben35096/assets/releases/download/yolo8/face_yolov8m-seg_60.pt; \
    fi

# Flux autoencoder, for the enhance and seedvr images. The FLUX.1-schnell repository
# is gated, so it is used only when a token is supplied; otherwise the same file comes
# from Comfy-Org's ungated repackage. The checksum is the same for both.
ARG FLUX_VAE_SHA256=afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38
ARG FLUX_VAE_UNGATED_URL=https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors
RUN --mount=type=secret,id=hf_token \
    set -eu; \
    if [ "$MODEL_TYPE" = "enhance" ] || [ "$MODEL_TYPE" = "seedvr" ]; then \
      if [ -s /run/secrets/hf_token ]; then \
        wget -nv --header="Authorization: Bearer $(cat /run/secrets/hf_token)" \
          -O /comfyui/models/vae/ae.safetensors \
          https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors; \
      else \
        wget -nv -O /comfyui/models/vae/ae.safetensors "${FLUX_VAE_UNGATED_URL}"; \
      fi; \
      echo "${FLUX_VAE_SHA256}  /comfyui/models/vae/ae.safetensors" | sha256sum -c -; \
    fi

# Flux text encoders, for the enhance and seedvr images.
RUN set -eux; \
    if [ "$MODEL_TYPE" = "enhance" ] || [ "$MODEL_TYPE" = "seedvr" ]; then \
      wget -nv -O /comfyui/models/text_encoders/clip_l.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors; \
      wget -nv -O /comfyui/models/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors \
        https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn_scaled.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-dev" ]; then \
      wget -q -O models/checkpoints/flux1-dev-fp8.safetensors https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "z-image-turbo" ]; then \
      wget -q -O models/text_encoders/qwen_3_4b.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors && \
      wget -q -O models/diffusion_models/z_image_turbo_bf16.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors && \
      wget -q -O models/vae/ae.safetensors https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors && \
      wget -q -O models/model_patches/Z-Image-Turbo-Fun-Controlnet-Union.safetensors https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union.safetensors; \
    fi

# SeedVR2 upscaler (the AZ-AI upscale graph Seedvr_flux_upscaler_02). The graph loads
# the mixed-precision SeedVR2 7B model; the plain FP8 name is kept as a link to it
# for graphs that still select the older file name. The Flux autoencoder and text
# encoders come from the shared steps above. No token is needed.
RUN set -eux; \
    if [ "$MODEL_TYPE" = "seedvr" ]; then \
      wget -nv -O /comfyui/models/SEEDVR2/ema_vae_fp16.safetensors \
        https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main/ema_vae_fp16.safetensors; \
      wget -nv -O /comfyui/models/SEEDVR2/seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors \
        https://huggingface.co/AInVFX/SeedVR2_comfyUI/resolve/main/seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors; \
      ln -s seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors \
        /comfyui/models/SEEDVR2/seedvr2_ema_7b_sharp_fp8_e4m3fn.safetensors; \
      wget -nv -O /comfyui/models/upscale_models/4xNomos8kDAT.pth \
        https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4xNomos8kDAT.pth; \
      # Fluxmania SVDQ fp4 (explicitly recommended for Blackwell/RTX 50-series)
      wget -nv -O /comfyui/models/diffusion_models/svdq-fp4_r32-fluxmania-legacy.safetensors \
        https://huggingface.co/spooknik/Fluxmania-SVDQ/resolve/main/svdq-fp4_r32-fluxmania-legacy.safetensors; \
    fi

# No `set -x` in the two steps below: they read the Hugging Face token.
RUN --mount=type=secret,id=hf_token \
  set -eu; \
  if [ "$MODEL_TYPE" = "flux2-klein" ]; then \
    wget -q -O models/depthanything/depth_anything_v2_vitl_fp16.safetensors \
      "https://huggingface.co/Kijai/DepthAnythingV2-safetensors/resolve/main/depth_anything_v2_vitl_fp16.safetensors?download=true"; \
    wget -q --header="Authorization: Bearer $(hf-token)" -O models/diffusion_models/flux-2-klein-9b-fp8.safetensors \
      "https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors"; \
    wget -q --header="Authorization: Bearer $(hf-token)" -O models/diffusion_models/flux-2-klein-base-9b-fp8.safetensors \
      "https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8/resolve/main/flux-2-klein-base-9b-fp8.safetensors"; \
    wget -q -O models/text_encoders/qwen_3_8b_fp8mixed.safetensors \
      "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors?download=true"; \
    wget -q -O models/vae/flux2-vae.safetensors \
      "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/vae/flux2-vae.safetensors?download=true"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q8_0.gguf"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-F16.gguf"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"; \
    test -s models/depthanything/depth_anything_v2_vitl_fp16.safetensors; \
    test -s models/diffusion_models/flux-2-klein-9b-fp8.safetensors; \
    test -s models/diffusion_models/flux-2-klein-base-9b-fp8.safetensors; \
    test -s models/text_encoders/qwen_3_8b_fp8mixed.safetensors; \
    test -s models/vae/flux2-vae.safetensors; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf; \
  fi

RUN --mount=type=secret,id=hf_token \
  set -eu; \
  if [ "$MODEL_TYPE" = "refrence_gen_sdxl_flux2_klein" ]; then \
    mkdir -p models/controlnet/controlnet-union-sdxl-1.0; \
    wget -q -O models/checkpoints/dreamshaperXL_v21TurboDPMSDE.safetensors \
      "https://huggingface.co/gingerlollipopdx/ModelsXL/resolve/main/dreamshaperXL_v21TurboDPMSDE.safetensors"; \
    wget -q -O models/depthanything/depth_anything_v2_vitl_fp16.safetensors \
      "https://huggingface.co/Kijai/DepthAnythingV2-safetensors/resolve/main/depth_anything_v2_vitl_fp16.safetensors?download=true"; \
    wget -q -O models/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors \
      "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors"; \
    wget -q -O models/ipadapter/ip_plus_composition_sdxl.safetensors \
      "https://huggingface.co/ostris/ip-composition-adapter/resolve/main/ip_plus_composition_sdxl.safetensors"; \
    wget -q -O models/ipadapter/ip-adapter_sdxl_vit-h.safetensors \
      "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter_sdxl_vit-h.safetensors"; \
    wget -q -O models/ipadapter/ip-adapter_sdxl.safetensors \
      "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter_sdxl.safetensors"; \
    wget -q -O models/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors \
      "https://huggingface.co/Kuvshin/models-moved/resolve/main/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"; \
    wget -q --header="Authorization: Bearer $(hf-token)" -O models/diffusion_models/flux-2-klein-9b-fp8.safetensors \
      "https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors"; \
    wget -q -O models/text_encoders/qwen_3_8b_fp8mixed.safetensors \
      "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors?download=true"; \
    wget -q -O models/vae/flux2-vae.safetensors \
      "https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/vae/flux2-vae.safetensors?download=true"; \
    wget -q -O models/controlnet/controlnet-union-sdxl-1.0/diffusion_pytorch_model_promax.safetensors \
      "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q8_0.gguf"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-F16.gguf"; \
    wget -q -O models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf \
      "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"; \
    test -s models/checkpoints/dreamshaperXL_v21TurboDPMSDE.safetensors; \
    test -s models/depthanything/depth_anything_v2_vitl_fp16.safetensors; \
    test -s models/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors; \
    test -s models/ipadapter/ip_plus_composition_sdxl.safetensors; \
    test -s models/ipadapter/ip-adapter_sdxl_vit-h.safetensors; \
    test -s models/ipadapter/ip-adapter_sdxl.safetensors; \
    test -s models/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors; \
    test -s models/diffusion_models/flux-2-klein-9b-fp8.safetensors; \
    test -s models/text_encoders/qwen_3_8b_fp8mixed.safetensors; \
    test -s models/vae/flux2-vae.safetensors; \
    test -s models/controlnet/controlnet-union-sdxl-1.0/diffusion_pytorch_model_promax.safetensors; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf; \
    test -s models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf; \
  fi

# The final stage copies the model folders one by one. A folder that is not in its
# list would silently be left out of the image, so fail here instead.
RUN set -eu; \
    for dir in /comfyui/models/*; do \
      case " checkpoints vae unet clip clip_vision text_encoders diffusion_models model_patches controlnet depthanything ipadapter loras SEEDVR2 upscale_models llm ultralytics sams " in \
        *" $(basename "$dir") "*) ;; \
        *) echo "$dir is not copied by the final stage: add it to the COPY lines there and to this list" >&2; exit 1 ;; \
      esac; \
    done


# Stage 3: Final image
FROM base AS final

# Copy models from stage 2 to the final image, one layer per model folder.
# A changed or added model then only replaces its own folder's layer when the
# image is pushed or pulled, and the layers download in parallel. --link keeps
# these layers independent of `base`, so a ComfyUI or PyTorch change reuses them.
COPY --link --from=downloader /comfyui/models/checkpoints /comfyui/models/checkpoints
COPY --link --from=downloader /comfyui/models/vae /comfyui/models/vae
COPY --link --from=downloader /comfyui/models/unet /comfyui/models/unet
COPY --link --from=downloader /comfyui/models/clip /comfyui/models/clip
COPY --link --from=downloader /comfyui/models/clip_vision /comfyui/models/clip_vision
COPY --link --from=downloader /comfyui/models/text_encoders /comfyui/models/text_encoders
COPY --link --from=downloader /comfyui/models/diffusion_models /comfyui/models/diffusion_models
COPY --link --from=downloader /comfyui/models/model_patches /comfyui/models/model_patches
COPY --link --from=downloader /comfyui/models/controlnet /comfyui/models/controlnet
COPY --link --from=downloader /comfyui/models/depthanything /comfyui/models/depthanything
COPY --link --from=downloader /comfyui/models/ipadapter /comfyui/models/ipadapter
COPY --link --from=downloader /comfyui/models/loras /comfyui/models/loras
COPY --link --from=downloader /comfyui/models/SEEDVR2 /comfyui/models/SEEDVR2
COPY --link --from=downloader /comfyui/models/upscale_models /comfyui/models/upscale_models
COPY --link --from=downloader /comfyui/models/llm /comfyui/models/llm
COPY --link --from=downloader /comfyui/models/ultralytics /comfyui/models/ultralytics
COPY --link --from=downloader /comfyui/models/sams /comfyui/models/sams

# Keep ComfyUI's core requirements complete in the runtime environment.
RUN /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/requirements.txt \
 && /opt/venv/bin/python -c "import sqlalchemy, torch; print('ComfyUI runtime dependencies OK:', 'SQLAlchemy', sqlalchemy.__version__, 'torch', torch.__version__, 'CUDA', torch.version.cuda)"

# --- flux2-klein image variant with bundled LoRAs ---
FROM final AS final-flux2-klein

# Copy LoRAs from build context into the image
COPY ./models/loras/klein9bDetailSlider.Xrt1.safetensors /comfyui/models/loras/
COPY ./models/loras/klein9bRealismSlider.U3P5.safetensors /comfyui/models/loras/
COPY ./models/loras/Klein_ref_transfer_02.safetensors /comfyui/models/loras/
COPY ./models/loras/lenovo_flux_klein9b.safetensors /comfyui/models/loras/
COPY ./models/loras/reccam_Klein_v01.safetensors /comfyui/models/loras/
COPY ./models/loras/Klein-consistency.safetensors /comfyui/models/loras/
COPY ./models/loras/realistic.safetensors /comfyui/models/loras/
COPY ./models/loras/FLUX.2-klein-base-9B_LoRa_by-AI_Characters_STYLE_SmartphoneSnapshotPhotoReality_v13.safetensors /comfyui/models/loras/
COPY ./models/loras/Klein_9B_bvfinish_v01.safetensors /comfyui/models/loras/
COPY ./models/loras/klein_archenhanced_refine_v11.safetensors /comfyui/models/loras/
COPY ./models/loras/sk2real_flux2_klein_9b_v9.9.safetensors /comfyui/models/loras/

# curl for the wheel download (base image installs wget but not curl)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install nodes via comfy-cli (registry). The defaults are the versions in the
# published flux2-klein9b:v06 image.
ARG DEPTHANYTHINGV2_VERSION=1.0.2
ARG QWENVL_VERSION=2.1.1
ARG CUSTOM_SCRIPTS_VERSION=1.2.5
RUN comfy-node-install \
  "comfyui-depthanythingv2@${DEPTHANYTHINGV2_VERSION}" \
  "ComfyUI-QwenVL@${QWENVL_VERSION}" \
  "comfyui-custom-scripts@${CUSTOM_SCRIPTS_VERSION}"

# Essentials pinned
ARG ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_essentials https://github.com/cubiq/ComfyUI_essentials.git "${ESSENTIALS_COMMIT}"

# KJNodes, at the commit in the published flux2-klein9b:v06 image
ARG KJNODES_COMMIT=3e80b28dec889b0d082c3bd3aeb0bf30ab6b5ab2
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-KJNodes https://github.com/kijai/ComfyUI-KJNodes.git "${KJNODES_COMMIT}"

# llama-cpp-python (Vision / Qwen-VL GGUF)
ARG LLAMA_CPP_WHEEL_URL=https://github.com/JamePeng/llama-cpp-python/releases/download/v0.3.30-cu128-Basic-linux-20260302/llama_cpp_python-0.3.30+cu128.basic-cp312-cp312-linux_x86_64.whl
ARG LLAMA_CPP_WHEEL_SHA256=a6a46176a1555a381100a6142dcd8f7fa269b1ecec66e6edefcc7f3a600a3143
RUN --mount=type=cache,target=/opt/wheels \
    --mount=type=bind,source=scripts/build/install-llama-vision.sh,target=/tmp/build/install-llama-vision.sh \
    bash /tmp/build/install-llama-vision.sh

# Ensure ComfyUI core Python deps (e.g. alembic/comfy_aimdo) match the bundled ComfyUI version.
RUN /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/requirements.txt

# Add runtime worker entrypoint files as the last layer for fast handler-only rebuilds
COPY --from=runtime-files /start.sh /network_volume.py /handler.py /test_input.json /
CMD ["/start.sh"]


# --- refrence_gen_sdxl_flux2_klein image variant ---
FROM final AS final-refrence_gen_sdxl_flux2_klein

# Copy LoRAs from build context into the image
COPY ./models/loras/klein_archenhanced_refine_v11.safetensors /comfyui/models/loras/
COPY ./models/loras/Klein_9B_bvfinish_v01.safetensors /comfyui/models/loras/

# curl for the wheel download (base image installs wget but not curl)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates pkg-config libcairo2-dev \
 && rm -rf /var/lib/apt/lists/*

# The revisions of this variant's nodes were never recorded, so each default is the
# repository's main branch. Pass a commit hash to pin one.

# Custom Scripts
ARG CUSTOM_SCRIPTS_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-Custom-Scripts https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git "${CUSTOM_SCRIPTS_COMMIT}"

# DepthAnythingV2
ARG DEPTHANYTHINGV2_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-DepthAnythingV2 https://github.com/kijai/ComfyUI-DepthAnythingV2.git "${DEPTHANYTHINGV2_COMMIT}"

# ControlNet Aux
ARG CONTROLNET_AUX_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh comfyui-controlnet-aux https://github.com/comfyorg/comfyui-controlnet-aux.git "${CONTROLNET_AUX_COMMIT}"

# LayerStyle
ARG LAYERSTYLE_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_LayerStyle https://github.com/chflame163/ComfyUI_LayerStyle.git "${LAYERSTYLE_COMMIT}"

# rgthree
ARG RGTHREE_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh rgthree-comfy https://github.com/rgthree/rgthree-comfy.git "${RGTHREE_COMMIT}"

# Essentials pinned
ARG ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_essentials https://github.com/cubiq/ComfyUI_essentials.git "${ESSENTIALS_COMMIT}"

# KJNodes
ARG KJNODES_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-KJNodes https://github.com/kijai/ComfyUI-KJNodes.git "${KJNODES_COMMIT}"

# QwenVL
ARG QWENVL_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-QwenVL https://github.com/1038lab/ComfyUI-QwenVL "${QWENVL_COMMIT}"

# Easy Use
ARG EASY_USE_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-Easy-Use https://github.com/yolain/ComfyUI-Easy-Use.git "${EASY_USE_COMMIT}"

# Tooling nodes
ARG TOOLING_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh comfyui-tooling-nodes https://github.com/Acly/comfyui-tooling-nodes.git "${TOOLING_COMMIT}"

# IPAdapter Plus
ARG IPADAPTER_PLUS_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_IPAdapter_plus https://github.com/cubiq/ComfyUI_IPAdapter_plus.git "${IPADAPTER_PLUS_COMMIT}"

# TinyTerra nodes
ARG TINYTERRA_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_tinyterraNodes https://github.com/TinyTerra/ComfyUI_tinyterraNodes.git "${TINYTERRA_COMMIT}"

# SDXL prompt styler
ARG SDXL_PROMPT_STYLER_COMMIT=main
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh sdxl_prompt_styler https://github.com/twri/sdxl_prompt_styler.git "${SDXL_PROMPT_STYLER_COMMIT}"

# llama-cpp-python (Vision / Qwen-VL GGUF)
ARG LLAMA_CPP_WHEEL_URL=https://github.com/JamePeng/llama-cpp-python/releases/download/v0.3.30-cu128-Basic-linux-20260302/llama_cpp_python-0.3.30+cu128.basic-cp312-cp312-linux_x86_64.whl
ARG LLAMA_CPP_WHEEL_SHA256=a6a46176a1555a381100a6142dcd8f7fa269b1ecec66e6edefcc7f3a600a3143
RUN --mount=type=cache,target=/opt/wheels \
    --mount=type=bind,source=scripts/build/install-llama-vision.sh,target=/tmp/build/install-llama-vision.sh \
    bash /tmp/build/install-llama-vision.sh

# Ensure ComfyUI core Python deps (e.g. alembic/comfy_aimdo) match the bundled ComfyUI version.
RUN /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/requirements.txt

# Add runtime worker entrypoint files as the last layer for fast handler-only rebuilds
COPY --from=runtime-files /start.sh /network_volume.py /handler.py /test_input.json /
CMD ["/start.sh"]


# --- seedvr image variant (the AZ-AI upscale worker) ---
#
# The node versions and commits below are the ones in the published seedvr:v04
# image, the last one built with the output.images handler contract that the AZ-AI
# backend validates. See docs/published-images.md.
FROM final AS final-seedvr

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install nodes via comfy-cli (registry)
ARG SEEDVR2_VERSION=2.5.22
ARG RGTHREE_VERSION=1.0.2605082257
ARG CUSTOM_SCRIPTS_VERSION=1.2.5
ARG DYPE_VERSION=2.3.0
ARG ULTIMATESDUPSCALE_VERSION=1.7.2
RUN comfy-node-install \
  "seedvr2_videoupscaler@${SEEDVR2_VERSION}" \
  "rgthree-comfy@${RGTHREE_VERSION}" \
  "comfyui-custom-scripts@${CUSTOM_SCRIPTS_VERSION}" \
  "ComfyUI-DyPE@${DYPE_VERSION}" \
  "comfyui_ultimatesdupscale@${ULTIMATESDUPSCALE_VERSION}"

# The registry installer does not always install the SeedVR2 node's own requirements.
# The node itself cannot be imported while the image is built (see the import check
# below), so check three of its dependencies here instead.
RUN /opt/venv/bin/python -m pip install --no-cache-dir \
      -r /comfyui/custom_nodes/seedvr2_videoupscaler/requirements.txt \
 && /opt/venv/bin/python -c "import gguf, omegaconf, rotary_embedding_torch; print('SeedVR2 runtime dependencies OK')"

# ComfyUI-nunchaku plugin pinned
ARG NUNCHAKU_COMFYUI_TAG=v1.2.1
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-nunchaku https://github.com/nunchaku-ai/ComfyUI-nunchaku "${NUNCHAKU_COMFYUI_TAG}"

# Offline versions file (prevents "minimal mode" warning)
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
      https://nunchaku.tech/cdn/nunchaku_versions.json \
      -o /comfyui/custom_nodes/ComfyUI-nunchaku/nunchaku_versions.json

RUN --mount=type=bind,source=scripts/build/patch-nunchaku-qwenimage.py,target=/tmp/build/patch-nunchaku-qwenimage.py \
    /opt/venv/bin/python /tmp/build/patch-nunchaku-qwenimage.py

# --- Nunchaku backend (THIS is what provides `import nunchaku`) ---
# Must match: cu12.8 + torch2.10 + cp312
ARG NUNCHAKU_WHEEL_URL=https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu12.8torch2.10-cp312-cp312-linux_x86_64.whl
RUN /opt/venv/bin/python -m pip install --no-cache-dir ${NUNCHAKU_WHEEL_URL} && \
    /opt/venv/bin/python -c "import nunchaku, importlib.metadata as m; print('nunchaku OK:', m.version('nunchaku'))"

# Essentials pinned
ARG ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_essentials https://github.com/cubiq/ComfyUI_essentials "${ESSENTIALS_COMMIT}"

# KJNodes pinned
ARG KJNODES_COMMIT=2ad360258fbe4008cfb1379df0436e78d597d19b
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-KJNodes https://github.com/kijai/ComfyUI-KJNodes.git "${KJNODES_COMMIT}"

# WAS pinned
ARG WAS_COMMIT=ea935d1044ae5a26efa54ebeb18fe9020af49a45
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh was-node-suite-comfyui https://github.com/WASasquatch/was-node-suite-comfyui.git "${WAS_COMMIT}"

# Keep ComfyUI core deps synced with the checked out ComfyUI version.
RUN /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/requirements.txt

# Start ComfyUI once on the CPU and fail the build if a custom node cannot be imported.
# The SeedVR2 node is the exception: it builds its device lists from the GPUs it
# finds and raises an error when there is none, so it only loads on a GPU host.
RUN --mount=type=bind,source=scripts/build/check-comfy-imports.sh,target=/tmp/build/check-comfy-imports.sh \
    COMFY_IMPORT_ALLOW_FAILED="seedvr2_videoupscaler" bash /tmp/build/check-comfy-imports.sh

# Fail the build, rather than the first job, when the final environment no longer
# matches the Nunchaku wheel's ABI or a workflow model is missing or altered.
RUN --mount=type=bind,source=scripts/build/verify-image.py,target=/tmp/build/verify-image.py \
    --mount=type=bind,source=workflows/seedvr-upscale/models.sha256,target=/tmp/build/models.sha256 \
    /opt/venv/bin/python /tmp/build/verify-image.py --models /tmp/build/models.sha256

# Add runtime worker entrypoint files as the last layer for fast handler-only rebuilds
COPY --from=runtime-files /start.sh /network_volume.py /handler.py /test_input.json /
CMD ["/start.sh"]


# --- enhance image variant ---
#
# Build strategy:
# 1) final-enhance-core = heavy layers (nodes, qwen/llama, model-adjacent setup)
# 2) final-enhance      = thin overlay for dependency hotfixes + runtime entrypoint files
#
# This lets us iterate on dependency fixes without rebuilding heavy stages.
FROM final AS final-enhance-core

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# Custom nodes needed by the workflow
# --------------------------------------------------

# Registry installs, at the versions in the validated v07 image
ARG RGTHREE_VERSION=1.0.2608210019
ARG CUSTOM_SCRIPTS_VERSION=1.2.5
ARG IMPACT_PACK_VERSION=8.28.3
ARG IMPACT_SUBPACK_VERSION=1.3.5
ARG EASY_USE_VERSION=1.3.6
RUN comfy-node-install \
  "rgthree-comfy@${RGTHREE_VERSION}" \
  "comfyui-custom-scripts@${CUSTOM_SCRIPTS_VERSION}" \
  "comfyui-impact-pack@${IMPACT_PACK_VERSION}" \
  "comfyui-impact-subpack@${IMPACT_SUBPACK_VERSION}" \
  "comfyui-easy-use@${EASY_USE_VERSION}"

# Essentials pinned
ARG ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI_essentials https://github.com/cubiq/ComfyUI_essentials "${ESSENTIALS_COMMIT}"

# WAS pinned
ARG WAS_COMMIT=ea935d1044ae5a26efa54ebeb18fe9020af49a45
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh was-node-suite-comfyui https://github.com/WASasquatch/was-node-suite-comfyui.git "${WAS_COMMIT}"

# QwenVL
ARG QWENVL_COMMIT=1b67b443918801f571714bab636edc1845b7002a
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-QwenVL https://github.com/1038lab/ComfyUI-QwenVL "${QWENVL_COMMIT}"

# Tooling nodes
ARG TOOLING_COMMIT=b3ae4aa2d98f6ac4284ddbe261e3559c94bd652b
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh comfyui-tooling-nodes https://github.com/Acly/comfyui-tooling-nodes.git "${TOOLING_COMMIT}"

# Post-processing nodes
ARG POST_COMMIT=c49a05254795403648f2c1774b6f5ea39f96e7d5
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-post-processing-nodes https://github.com/EllangoK/ComfyUI-post-processing-nodes.git "${POST_COMMIT}"

# --------------------------------------------------
# ComfyUI-Nunchaku
# --------------------------------------------------

ARG NUNCHAKU_COMFYUI_TAG=v1.2.1
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-nunchaku https://github.com/nunchaku-ai/ComfyUI-nunchaku "${NUNCHAKU_COMFYUI_TAG}"

# Offline versions file
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
      https://nunchaku.tech/cdn/nunchaku_versions.json \
      -o /comfyui/custom_nodes/ComfyUI-nunchaku/nunchaku_versions.json

# ComfyUI-nunchaku imports apply_rotary_emb from ComfyUI's Qwen-Image model. ComfyUI
# releases that do not export it break the import of the whole node package,
# NunchakuFluxDiTLoader included, so use the equivalent Flux helper there.
RUN --mount=type=bind,source=scripts/build/patch-nunchaku-qwenimage.py,target=/tmp/build/patch-nunchaku-qwenimage.py \
    /opt/venv/bin/python /tmp/build/patch-nunchaku-qwenimage.py

# Nunchaku backend wheel
ARG NUNCHAKU_WHEEL_URL=https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu12.8torch2.10-cp312-cp312-linux_x86_64.whl
RUN /opt/venv/bin/python -m pip install --no-cache-dir ${NUNCHAKU_WHEEL_URL} \
 && /opt/venv/bin/python -c "import nunchaku, importlib.metadata as m; print('nunchaku OK:', m.version('nunchaku'))"

# --------------------------------------------------
# llama-cpp-python (Vision / Qwen-VL GGUF)
# --------------------------------------------------

ARG LLAMA_CPP_WHEEL_URL=https://github.com/JamePeng/llama-cpp-python/releases/download/v0.3.30-cu128-Basic-linux-20260302/llama_cpp_python-0.3.30+cu128.basic-cp312-cp312-linux_x86_64.whl
ARG LLAMA_CPP_WHEEL_SHA256=a6a46176a1555a381100a6142dcd8f7fa269b1ecec66e6edefcc7f3a600a3143
RUN --mount=type=cache,target=/opt/wheels \
    --mount=type=bind,source=scripts/build/install-llama-vision.sh,target=/tmp/build/install-llama-vision.sh \
    bash /tmp/build/install-llama-vision.sh

# Thin, rebuild-friendly overlay stage.
# By default this uses the in-file core stage; for fast hotfix builds on fresh machines,
# pass a prebuilt image, e.g.:
#   --build-arg ENHANCE_CORE_IMAGE=momensirribrick/general-enhancement:core-v07
FROM ${ENHANCE_CORE_IMAGE} AS final-enhance

# Keep ComfyUI core deps synced with the checked out ComfyUI version.
RUN /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/requirements.txt

# Runtime deps that are occasionally missing depending on custom node resolution.
RUN /opt/venv/bin/python -m pip install --no-cache-dir \
    piexif \
    ultralytics \
    segment-anything \
    dill

# Thin-layer enhance-specific model additions.
# Keep this in final-enhance so new workflow weights can be shipped without rebuilding the heavy core.
ARG FLUXMANIA_SVDQ_INT4_URL=https://huggingface.co/spooknik/Fluxmania-SVDQ/resolve/main/svdq-int4_r32-fluxmania-legacy.safetensors
RUN mkdir -p /comfyui/models/diffusion_models \
 && wget -nv -O /comfyui/models/diffusion_models/svdq-int4_r32-fluxmania-legacy.safetensors ${FLUXMANIA_SVDQ_INT4_URL} \
 && test -s /comfyui/models/diffusion_models/svdq-int4_r32-fluxmania-legacy.safetensors

# Thin-layer custom node install: momi_gpu_model_selector
# Keep this in final-enhance so local node changes stay fast to rebuild.
COPY ./custom_nodes/momi_gpu_model_selector /comfyui/custom_nodes/momi_gpu_model_selector
RUN set -eux; \
    if [ -f /comfyui/custom_nodes/momi_gpu_model_selector/requirements.txt ]; then \
      /opt/venv/bin/python -m pip install --no-cache-dir -r /comfyui/custom_nodes/momi_gpu_model_selector/requirements.txt; \
    fi; \
    /opt/venv/bin/python - <<'PY'
import importlib.util
from pathlib import Path

module_path = Path("/comfyui/custom_nodes/momi_gpu_model_selector/__init__.py")
spec = importlib.util.spec_from_file_location("momi_gpu_model_selector", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert "MomiNunchakuFluxGPUModelSelector" in module.NODE_CLASS_MAPPINGS
assert module.NODE_DISPLAY_NAME_MAPPINGS["MomiNunchakuFluxGPUModelSelector"] == "Nunchaku Flux GPU Model Selector"
print("momi_gpu_model_selector OK")
PY

# Thin-layer custom node install: ComfyUI-Inpaint-CropAndStitch
# Keep this in final-enhance so we can add/fix nodes without rebuilding heavy core layers.
ARG CROP_STITCH_COMMIT=8584b08d851762965df898b421a39075fc5357ae
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-Inpaint-CropAndStitch https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git "${CROP_STITCH_COMMIT}"

# Thin-layer custom node install: ComfyUI-KJNodes
# Keep this in final-enhance so we can add/fix nodes without rebuilding heavy core layers.
ARG KJNODES_COMMIT=d3cfe21625e5170126ce06fbfcfe1d88108688c3
RUN --mount=type=bind,source=scripts/build/node-git.sh,target=/tmp/build/node-git.sh \
    bash /tmp/build/node-git.sh ComfyUI-KJNodes https://github.com/kijai/ComfyUI-KJNodes.git "${KJNODES_COMMIT}"

# ComfyUI-QwenVL resolves its models under models/LLM/GGUF and only falls back to an
# all-lowercase llm/gguf, while the files are bundled under models/llm/GGUF. Without
# this link the node still finds the model through its recursive search, but not the
# vision projector, and downloads it from Hugging Face on every cold start.
RUN [ -e /comfyui/models/LLM ] || ln -s llm /comfyui/models/LLM

# Start ComfyUI once on the CPU and fail the build if a custom node cannot be imported.
RUN --mount=type=bind,source=scripts/build/check-comfy-imports.sh,target=/tmp/build/check-comfy-imports.sh \
    bash /tmp/build/check-comfy-imports.sh

# Fail the build, rather than the first job, when the final environment no longer
# matches the Nunchaku wheel's ABI or a workflow model is missing or altered.
RUN --mount=type=bind,source=scripts/build/verify-image.py,target=/tmp/build/verify-image.py \
    --mount=type=bind,source=workflows/general-enhancement/models.sha256,target=/tmp/build/models.sha256 \
    /opt/venv/bin/python /tmp/build/verify-image.py \
      --models /tmp/build/models.sha256 \
      --qwenvl Qwen3-VL-4B-Instruct-GGUF Qwen3VL-4B-Instruct-Q8_0.gguf

# Add runtime worker entrypoint files as the last layer for fast handler-only rebuilds
COPY --from=runtime-files /start.sh /network_volume.py /handler.py /test_input.json /
CMD ["/start.sh"]
