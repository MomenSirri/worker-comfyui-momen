variable "DOCKERHUB_REPO" {
  default = "momensirribrick"
}

variable "DOCKERHUB_IMG" {
  default = "worker-comfyui"
}

variable "RELEASE_VERSION" {
  default = "latest"
}

variable "FLUX2_KLEIN_IMG" {
  default = "flux2-klein9b"
}

# Image tags. Docker Hub already has flux2-klein9b:v01-v06 and seedvr:v01-v06, and a
# push to an existing tag replaces it. Set the next free tag for every release.
variable "FLUX2_KLEIN_TAG" {
  default = "v07"
}

variable "SEEDVR_TAG" {
  default = "v07"
}

# ComfyUI releases. `latest` is deliberately not a default: a production image must
# not change because a new ComfyUI was released.
#   0.38.0 is the release the General Enhancement image v07 was validated with.
#   0.24.1 is the release in the published seedvr:v04 and flux2-klein9b:v06 images.
variable "COMFYUI_VERSION" {
  default = "0.38.0"
}

variable "SEEDVR_COMFYUI_VERSION" {
  default = "0.24.1"
}

variable "FLUX2_KLEIN_COMFYUI_VERSION" {
  default = "0.24.1"
}

# Global defaults for standard CUDA 12.6.3 images
variable "BASE_IMAGE" {
  default = "nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04"
}

variable "CUDA_VERSION_FOR_COMFY" {
  default = "12.6"
}

variable "ENABLE_PYTORCH_UPGRADE" {
  default = "false"
}

variable "PYTORCH_INDEX_URL" {
  default = ""
}

variable "KREAMANIA_FP8_SHA256" {
  default = ""
}

# Bundle enhancement assets that no General Enhancement graph selects (about 19 GB).
variable "ENHANCE_EXTRA_MODELS" {
  default = "false"
}

variable "ENHANCE_CORE_IMAGE" {
  # Default to local build stage alias; override with a pushed core image to skip heavy rebuilds.
  # Example override:
  # --set enhance.args.ENHANCE_CORE_IMAGE=momensirribrick/general-enhancement:core-v07
  default = "final-enhance-core"
}

# `docker buildx bake` without a target builds only the General Enhancement image.
# Name every other image explicitly: each one is tens of gigabytes.
group "default" {
  targets = ["enhance"]
}

# The two AZ-AI workers: enhancement and upscale.
group "azai" {
  targets = ["enhance", "seedvr"]
}

# Shared by every target. Access tokens are passed as BuildKit secrets, read from
# the environment variables HUGGINGFACE_ACCESS_TOKEN and CIVITAI_API_TOKEN when
# they are set. They are never build arguments.
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  secret = [
    "id=hf_token,env=HUGGINGFACE_ACCESS_TOKEN",
    "id=civitai_token,env=CIVITAI_API_TOKEN",
  ]
}

# Standard CUDA 12.6 images: comfy-cli installs PyTorch.
target "_cuda126" {
  inherits = ["_common"]
  args = {
    BASE_IMAGE             = "${BASE_IMAGE}"
    COMFYUI_VERSION        = "${COMFYUI_VERSION}"
    CUDA_VERSION_FOR_COMFY = "${CUDA_VERSION_FOR_COMFY}"
    ENABLE_PYTORCH_UPGRADE = "${ENABLE_PYTORCH_UPGRADE}"
    PYTORCH_INDEX_URL      = "${PYTORCH_INDEX_URL}"
  }
}

# CUDA 12.8.1 images (RTX 50-series): PyTorch comes from the cu128 wheel index.
target "_cuda128" {
  inherits = ["_common"]
  args = {
    BASE_IMAGE             = "nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04"
    COMFYUI_VERSION        = "${COMFYUI_VERSION}"
    CUDA_VERSION_FOR_COMFY = ""
    ENABLE_PYTORCH_UPGRADE = "true"
    PYTORCH_INDEX_URL      = "https://download.pytorch.org/whl/cu128"
  }
}

# The bundled Nunchaku wheel is built for PyTorch 2.10 / CUDA 12.8. The final
# build check fails when PyTorch does not match it.
target "_cuda128_torch210" {
  inherits = ["_cuda128"]
  args = {
    PYTORCH_VERSION     = "2.10.0"
    TORCHVISION_VERSION = "0.25.0"
    TORCHAUDIO_VERSION  = "2.10.0"
  }
}

target "base" {
  inherits = ["_cuda126"]
  target   = "base"
  args = {
    MODEL_TYPE = "base"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-base"]
}

target "sd3" {
  inherits = ["_cuda126"]
  target   = "final"
  args = {
    MODEL_TYPE = "sd3"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-sd3"]
}

target "flux1-schnell" {
  inherits = ["_cuda126"]
  target   = "final"
  args = {
    MODEL_TYPE = "flux1-schnell"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-flux1-schnell"]
}

target "flux1-dev" {
  inherits = ["_cuda126"]
  target   = "final"
  args = {
    MODEL_TYPE = "flux1-dev"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-flux1-dev"]
}

target "z-image-turbo" {
  inherits = ["_cuda126"]
  target   = "final"
  args = {
    MODEL_TYPE = "z-image-turbo"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-z-image-turbo"]
}

target "base-cuda12-8-1" {
  inherits = ["_cuda128"]
  target   = "base"
  args = {
    MODEL_TYPE = "base"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-base-cuda12.8.1"]
}

target "flux2-klein" {
  inherits = ["_cuda126"]
  target   = "final-flux2-klein"
  args = {
    COMFYUI_VERSION = "${FLUX2_KLEIN_COMFYUI_VERSION}"
    MODEL_TYPE      = "flux2-klein"
  }
  tags = ["${DOCKERHUB_REPO}/${FLUX2_KLEIN_IMG}:${FLUX2_KLEIN_TAG}-cuda12.6"]
}

# FLUX.2 Klein 9B with its LoRAs (CUDA 12.8.1 + cu128 torch wheels). Needs the
# LoRA files in ./models/loras and a Hugging Face token for the gated weights.
target "flux2-klein-cuda12-8-1" {
  inherits = ["_cuda128"]
  target   = "final-flux2-klein"
  args = {
    COMFYUI_VERSION = "${FLUX2_KLEIN_COMFYUI_VERSION}"
    MODEL_TYPE      = "flux2-klein"
  }
  tags = ["${DOCKERHUB_REPO}/${FLUX2_KLEIN_IMG}:${FLUX2_KLEIN_TAG}"]
}

target "refrence_gen_sdxl_flux2_klein" {
  inherits = ["_cuda126"]
  target   = "final-refrence_gen_sdxl_flux2_klein"
  args = {
    MODEL_TYPE = "refrence_gen_sdxl_flux2_klein"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-refrence_gen_sdxl_flux2_klein"]
}

target "refrence_gen_sdxl_flux2_klein-cuda12-8-1" {
  inherits = ["_cuda128"]
  target   = "final-refrence_gen_sdxl_flux2_klein"
  args = {
    MODEL_TYPE = "refrence_gen_sdxl_flux2_klein"
  }
  tags = ["${DOCKERHUB_REPO}/${DOCKERHUB_IMG}:${RELEASE_VERSION}-refrence_gen_sdxl_flux2_klein-cuda12.8.1"]
}

# SeedVR2 upscaler: the AZ-AI upscale worker. Needs no token and no local files.
target "seedvr" {
  inherits = ["_cuda128_torch210"]
  target   = "final-seedvr"
  args = {
    COMFYUI_VERSION = "${SEEDVR_COMFYUI_VERSION}"
    MODEL_TYPE      = "seedvr"
  }
  tags = ["${DOCKERHUB_REPO}/seedvr:${SEEDVR_TAG}"]
}

# Earlier name of the `seedvr` target.
target "seedvr-cuda12-8-1" {
  inherits = ["seedvr"]
}

# General Enhancement: the AZ-AI enhancement worker. Set RELEASE_VERSION to the tag.
target "enhance-core" {
  inherits = ["_cuda128_torch210"]
  target   = "final-enhance-core"
  args = {
    MODEL_TYPE           = "enhance"
    PIP_CONSTRAINTS_FILE = "constraints/general-enhancement-v07.txt"
    ENHANCE_EXTRA_MODELS = "${ENHANCE_EXTRA_MODELS}"
    KREAMANIA_FP8_SHA256 = "${KREAMANIA_FP8_SHA256}"
  }
  tags = ["${DOCKERHUB_REPO}/general-enhancement:core-${RELEASE_VERSION}"]
}

target "enhance" {
  inherits = ["enhance-core"]
  target   = "final-enhance"
  args = {
    ENHANCE_CORE_IMAGE = "${ENHANCE_CORE_IMAGE}"
  }
  tags = ["${DOCKERHUB_REPO}/general-enhancement:${RELEASE_VERSION}"]
}
