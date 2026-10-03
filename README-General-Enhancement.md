# General Enhancement — build and setup

This guide covers Bake target `enhance`, Docker target `final-enhance`, and image `momensirribrick/general-enhancement`. The example release tag in `command.txt` and the enhancement Compose override is `v05`; Bake defaults to `latest` unless `RELEASE_VERSION` is set. Image tags are project releases, not ComfyUI versions.

## Workflow audited

Dependencies were identified from the actual [API workflow v1.19](workflows/general-enhancement/workflow_api_flux_dev_1.19.json), supplied from `workflow_api_flux_dev_1.19 .json`. The repository copy preserves the source bytes: 86 nodes, 55 distinct node classes, SHA256 `b64fd473e3ec6b6cc2707e1c9ae664aed4c55cad605ed10adebd07de6f42f1fd`.

The graph performs Fluxmania person/face detailing, Qwen image description, tiled SD 1.5 refinement, ReFocus processing, Flux tile refinement, and crop/stitch output. Node `83` is the final `SaveImage`. This is an API-format graph, not a UI graph with positions/widgets: execute it through the worker API. A UI-format authoring version is not supplied.

This document separates graph dependencies from additional assets installed by the target. Docker configuration and upstream registrations were inspected. **A Docker build and GPU inference were not verified during this audit because the local Docker daemon was unavailable.** Use the preflight and execution checks below to validate your image.

## 1. Prerequisites

- NVIDIA CUDA GPU and a host driver compatible with CUDA 12.8. The supplied graph selects Blackwell FP4 weights; compatible non-Blackwell GPUs need the INT4 adaptation below.
- Docker Engine/Desktop with BuildKit/Buildx and GPU access. On Linux configure [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html). On Windows use Linux containers with [Docker Desktop WSL2 GPU support](https://docs.docker.com/desktop/features/gpu/).
- Git and build-time access to GitHub, Hugging Face, Civitai, PyPI, the PyTorch wheel index, and Ubuntu repositories. Host Python 3.10+ is needed only for the included standard-library test helper; the container uses Python 3.12.
- Sufficient disk for several large diffusion models, Qwen, the final image, and intermediate BuildKit layers. No minimum disk/RAM/VRAM requirement has been measured for this graph. All bundled models download even when this graph does not use them.
- Model access/license acceptance and a Hugging Face read token when required. Civitai authorization may be needed for bundled Kreamania, although v1.19 does not select it.

Check the host first:

```bash
docker version
docker buildx version
docker run --rm --gpus all nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04 nvidia-smi
```

## 2. Versions and compatibility

| Component | Build configuration / requirement |
| --- | --- |
| Platform | `linux/amd64`; bundled binary wheels do not target Windows or ARM. |
| OS/CUDA | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04`. Use this enhancement-specific base, rather than Bake's global CUDA 12.6 default. |
| Python | 3.12; actual runtime environment `/opt/venv`. Use `/opt/venv/bin/python -m pip`; comfy-cli also creates a workspace environment. |
| ComfyUI | `COMFYUI_VERSION=latest`. **No pinned, validated ComfyUI release/commit is recorded for this target.** The selected version must provide every core class in the graph, including `GetImageSize` and Flux sampling, and support the custom-node APIs. |
| PyTorch | Default upgrade from `https://download.pytorch.org/whl/cu128` is unpinned. The chosen Nunchaku wheel requires Torch **2.10**, CUDA **12.8**, Python **3.12**. Build examples below request Torch 2.10.0, torchvision 0.25.0, torchaudio 2.10.0; verify final versions after node installs. |
| ComfyUI-Nunchaku | `NUNCHAKU_COMFYUI_TAG=v1.2.1`. |
| Nunchaku backend | `1.2.1+cu12.8torch2.10`, `cp312`, `linux_x86_64`, from the [v1.2.1 release](https://github.com/nunchaku-ai/nunchaku/releases/tag/v1.2.1). Match node/backend, Torch, CUDA, Python ABI, and quantization. |
| llama-cpp-python | Repository `JamePeng/llama-cpp-python`, release `v0.3.30-cu128-Basic-linux-20260302`, Python tag `cp312`. The installer selects a matching Linux wheel and checks source for `Qwen3VLChatHandler` and `Qwen25VLChatHandler`; it does not test CUDA inference during the build. |

Do not select an arbitrary old ComfyUI or upgrade Torch independently. The version requests above align with the configured wheel ABI; they are not a claim that the complete stack has been tested. For reproducibility, replace `latest`/moving node branches with tested versions/commits, and record Git revisions, `pip freeze`, model hashes, and the image digest after a successful full run.

### GPU selection

Node `40` directly loads `svdq-fp4_r32-fluxmania-legacy.safetensors`, with `device_id=0`, `data_type=bfloat16`, `attention=nunchaku-fp16`, `cpu_offload=auto`, and `i2f_mode=enabled`.

- For the Blackwell FP4 path, retain that filename.
- For a supported non-Blackwell GPU such as an RTX 4090, change node `40`'s `model_path` to `svdq-int4_r32-fluxmania-legacy.safetensors`, or use the helper's `--int4` flag. Both files are bundled. Nunchaku hardware compatibility still needs validation on the chosen GPU.
- The local `MomiNunchakuFluxGPUModelSelector` is included in the image but **absent from v1.19**: no automatic fallback occurs. Its implementation classifies exactly capability `12.0` (`sm_120`) as the Blackwell FP4 path, not every possible Blackwell device.
- The workflow uses GPU 0. Installing the selector does not route this graph to another GPU; CPU preprocessing at node `34` does not make diffusion CPU-compatible.

## 3. Models selected by the workflow

Paths are exact **container paths**, case-sensitive on Linux. For manual ComfyUI replace `/comfyui` with its root. Retain filenames because the graph uses literal names. Rows marked bundled are downloaded by this target. Hugging Face sources mostly use mutable `main`, not hash-pinned revisions.

| Model / version or variant | Node | Exact destination | Download source | Bundled |
| --- | --- | --- | --- | --- |
| epiCRealism Natural Sin RC1, included VAE, SD 1.5 | `36` | `/comfyui/models/checkpoints/epicrealism_naturalSinRC1VAE.safetensors` | [philz1337x/epicrealism](https://huggingface.co/philz1337x/epicrealism/resolve/main/epicrealism_naturalSinRC1VAE.safetensors) | Yes |
| Detail Slider ALT2, SD 1.5 LoRA | `37` | `/comfyui/models/loras/detailSliderALT2.safetensors` | [iamanaiart/flatloras](https://huggingface.co/iamanaiart/flatloras/resolve/main/detailSliderALT2.safetensors) | Yes |
| Fluxmania legacy SVDQ FP4, rank 32 | `40` | `/comfyui/models/diffusion_models/svdq-fp4_r32-fluxmania-legacy.safetensors` | [spooknik/Fluxmania-SVDQ](https://huggingface.co/spooknik/Fluxmania-SVDQ/resolve/main/svdq-fp4_r32-fluxmania-legacy.safetensors) | Yes |
| Fluxmania legacy SVDQ INT4, rank 32 | Adaptation of `40` | `/comfyui/models/diffusion_models/svdq-int4_r32-fluxmania-legacy.safetensors` | [spooknik/Fluxmania-SVDQ](https://huggingface.co/spooknik/Fluxmania-SVDQ/resolve/main/svdq-int4_r32-fluxmania-legacy.safetensors) | Yes, final overlay |
| Flux CLIP-L | `39` | `/comfyui/models/text_encoders/clip_l.safetensors` | [comfyanonymous/flux_text_encoders](https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors) | Yes |
| T5-XXL scaled FP8 E4M3FN | `39` | `/comfyui/models/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors` | [comfyanonymous/flux_text_encoders](https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn_scaled.safetensors) | Yes |
| Flux autoencoder from FLUX.1-schnell | `41` | `/comfyui/models/vae/ae.safetensors` | [black-forest-labs/FLUX.1-schnell](https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors) | Yes |
| Qwen3-VL 4B Instruct Q8_0 GGUF | `33` | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf` | [Qwen/Qwen3-VL-4B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q8_0.gguf) | Yes |
| Matching Qwen3-VL 4B Instruct F16 vision projector | Implicit for `33` | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf` | [Qwen F16 mmproj](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-F16.gguf) | Yes |
| 1x ReFocus V3 | `19` | `/comfyui/models/upscale_models/1x-ReFocus-V3.pth` | [notkenski/upscalers](https://huggingface.co/notkenski/upscalers/resolve/main/1x-ReFocus-V3.pth) | Yes |
| SAM ViT-B checkpoint 01ec64 | `46`, `55` | `/comfyui/models/sams/sam_vit_b_01ec64.pth` | [Meta SAM](https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth) | Yes |
| Face YOLOv8m bbox | `56` | `/comfyui/models/ultralytics/bbox/face_yolov8m.pt` | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt) | Yes |
| Person YOLOv8m segmentation | `42`, `43` | `/comfyui/models/ultralytics/segm/person_yolov8m-seg.pt` | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt) | Yes |
| Face YOLOv8m segmentation, `_60` artifact | `57` | `/comfyui/models/ultralytics/segm/face_yolov8m-seg_60.pt` | [hben35096/assets, yolo8 release](https://github.com/hben35096/assets/releases/download/yolo8/face_yolov8m-seg_60.pt) | Yes |
| EasyNegative embedding | `27` prompt | `/comfyui/models/embeddings/easynegative.safetensors` | [EvilEngine/easynegative mirror](https://huggingface.co/EvilEngine/easynegative/resolve/main/easynegative.safetensors); [source attribution](https://huggingface.co/EvilEngine/easynegative) | **No** |
| epiCNegative embedding | `27` prompt | `/comfyui/models/embeddings/epiCNegative.safetensors`, or original compatible `.pt` with this stem | **Exact original version/source is not recorded and was not verified. Obtain the original from the workflow owner.** | **No** |

Node `37` has `strength_model=0` but `strength_clip≈1`, so its LoRA is still a dependency. Node `33` names only the GGUF; the [QwenVL model configuration](https://github.com/1038lab/ComfyUI-QwenVL/blob/main/gguf_models.json) identifies its matching F16 projector. The image also downloads a Q8_0 projector, but this graph does not explicitly select it.

### Missing embeddings: faithful setup or explicit adaptation

For faithful conditioning supply both embeddings with exact stems `easynegative` and `epiCNegative`; preserve case on Linux. Names alone do not identify their original versions/hashes. The EasyNegative mirror is a download source, not proof of the original artifact. epiCNegative's provenance remains unresolved.

Mount a host `embeddings/` folder to `/comfyui/models/embeddings`, or bake a child image:

```dockerfile
FROM momensirribrick/general-enhancement:v05
COPY embeddings/ /comfyui/models/embeddings/
```

Place files in a top-level `embeddings/` directory for this child build: the existing `.dockerignore` excludes most local `models/` paths. Merely placing files under local `models/embeddings` will not package them. Runtime mount option, added to `docker run`:

```bash
--mount type=bind,src="$PWD/embeddings",dst=/comfyui/models/embeddings,readonly
```

Alternatively the helper's `--without-embeddings` removes the two `embedding:` references from a generated request. **This changes negative conditioning** and does not reproduce the original exactly. It leaves the source workflow intact and lets you test the remaining graph without the unresolved epiCNegative file. Missing embeddings may produce warnings rather than hard failures, so job success alone does not prove they loaded.

### Additional bundled assets, unused by v1.19

These still increase build storage/time and their download failures can stop the build:

| Asset | Exact destination | Source |
| --- | --- | --- |
| Nunchaku FLUX.1-dev FP4 rank 32 | `/comfyui/models/diffusion_models/svdq-fp4_r32-flux.1-dev.safetensors` | [nunchaku-ai/nunchaku-flux.1-dev](https://huggingface.co/nunchaku-ai/nunchaku-flux.1-dev/resolve/main/svdq-fp4_r32-flux.1-dev.safetensors) |
| Fluxmania Kreamania FP8, Civitai version ID `2106807` | `/comfyui/models/diffusion_models/fluxmania_kreamania.safetensors` | [model page](https://civitai.com/models/778691/fluxmania), [exact API download](https://civitai.com/api/download/models/2106807?type=Model&format=SafeTensor&size=full&fp=fp8) |
| Boreal Flux-dev LoRA v04, 1000 steps | `/comfyui/models/loras/boreal-flux-dev-lora-v04_1000_steps.safetensors` | [kudzueye/Boreal](https://huggingface.co/kudzueye/Boreal/resolve/main/boreal-flux-dev-lora-v04_1000_steps.safetensors) |
| XLabs Flux Realism LoRA, renamed | `/comfyui/models/loras/flux-RealismLora.safetensors` | [XLabs-AI/flux-RealismLora/lora.safetensors](https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors) |
| Qwen3-VL 4B Instruct Q8_0 projector | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf` | [Qwen Q8_0 mmproj](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf) |

SeedVR2, ControlNet, IPAdapter, and Flux2-Klein are not referenced by v1.19. Their unrelated Docker stages/local model files are not needed for `final-enhance`.

## 4. Custom nodes

The target installs these automatically. For manual setup clone each repository under `/comfyui/custom_nodes/`, check out the listed revision, install its `requirements.txt` when present using the runtime Python, and restart ComfyUI. Registry installs resolve versions at build time. Git arguments defaulting to `main` skip explicit checkout and retain the upstream default branch, which need not actually be named `main`.

| Repository | Build revision/install ID | Actual graph classes |
| --- | --- | --- |
| [cubiq/ComfyUI_essentials](https://github.com/cubiq/ComfyUI_essentials) | `ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9` | `ImageResize+`, `GetImageSize+`, `ImageTile+`, `ImageUntile+`, `ImageListToBatch+`, `ImageFromBatch+`, `SimpleMath+`, `MaskBlur+` |
| [pythongosssss/ComfyUI-Custom-Scripts](https://github.com/pythongosssss/ComfyUI-Custom-Scripts) | Registry `comfyui-custom-scripts`, unpinned | `StringFunction\|pysssss` |
| [ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) | Registry `comfyui-impact-pack`, unpinned | `ImpactImageBatchToImageList`, `ToDetailerPipe`, `ToBasicPipe`, `FromBasicPipe`, `SAMLoader`, `FaceDetailerPipe` |
| [ltdrdata/ComfyUI-Impact-Subpack](https://github.com/ltdrdata/ComfyUI-Impact-Subpack) | Registry `comfyui-impact-subpack`, unpinned | `UltralyticsDetectorProvider`; pair with Impact Pack |
| [yolain/ComfyUI-Easy-Use](https://github.com/yolain/ComfyUI-Easy-Use) | Registry `comfyui-easy-use`, unpinned | `easy imageToBase64`, `easy int`, `easy imageListToImageBatch` |
| [1038lab/ComfyUI-QwenVL](https://github.com/1038lab/ComfyUI-QwenVL) | `QWENVL_COMMIT=main`, moving | `AILab_QwenVL_GGUF` |
| [Acly/comfyui-tooling-nodes](https://github.com/Acly/comfyui-tooling-nodes) | `TOOLING_COMMIT=main`, moving | `ETN_LoadImageBase64` |
| [EllangoK/ComfyUI-post-processing-nodes](https://github.com/EllangoK/ComfyUI-post-processing-nodes) | `POST_COMMIT=main`, moving | `Blend` (not core `ImageBlend`) |
| [nunchaku-ai/ComfyUI-nunchaku](https://github.com/nunchaku-ai/ComfyUI-nunchaku) | `NUNCHAKU_COMFYUI_TAG=v1.2.1` | `NunchakuFluxDiTLoader` |
| [lquesada/ComfyUI-Inpaint-CropAndStitch](https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch) | `CROP_STITCH_COMMIT=main`, moving | `InpaintCropImproved`, `InpaintStitchImproved` |
| [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `KJNODES_COMMIT=main`, moving | `ImagePass`, `ImageResizeKJv2` |

The remaining 28 distinct classes are ComfyUI core/extras nodes, including `GetImageSize` without `+`. No additional third-party `GetImageSize` package is needed when ComfyUI supplies it.

Also installed but **not referenced by this graph**:

- [rgthree/rgthree-comfy](https://github.com/rgthree/rgthree-comfy), registry `rgthree-comfy`, unpinned.
- [WASasquatch/was-node-suite-comfyui](https://github.com/WASasquatch/was-node-suite-comfyui), `WAS_COMMIT=ea935d1044ae5a26efa54ebeb18fe9020af49a45`.
- [Local GPU selector](custom_nodes/momi_gpu_model_selector/__init__.py), copied from this repository, no independent public node repository/additional requirements file; depends on Torch and ComfyUI model management.

Manual Git installation example (Linux/container shell):

```bash
git clone https://github.com/cubiq/ComfyUI_essentials /comfyui/custom_nodes/ComfyUI_essentials
git -C /comfyui/custom_nodes/ComfyUI_essentials checkout 9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
/opt/venv/bin/python -m pip install -r /comfyui/custom_nodes/ComfyUI_essentials/requirements.txt
```

Repeat using each table repository/revision; install a requirements file only if it exists. Registry installation in Docker uses the bundled [comfy-node-install wrapper](scripts/comfy-node-install.sh):

```bash
comfy-node-install rgthree-comfy comfyui-custom-scripts comfyui-impact-pack comfyui-impact-subpack comfyui-easy-use
```

This calls `comfy node install --mode=remote`. Git installs instead of registry installs need their own recorded commits and do not automatically reproduce an earlier registry resolution.

Nunchaku needs both its node repository and backend wheel. Docker also saves `https://nunchaku.tech/cdn/nunchaku_versions.json` at `/comfyui/custom_nodes/ComfyUI-nunchaku/nunchaku_versions.json`. Qwen GGUF needs both its node and the vision-capable llama-cpp wheel; Transformers alone does not provide that backend.

## 5. Python and OS dependencies

The [Dockerfile](Dockerfile) defines the installation order:

- OS: `python3.12`, `python3.12-venv`, `python3-pip`, `git`, `wget`, `libgl1`, `libglib2.0-0`, `libsm6`, `libxext6`, `libxrender1`, `ffmpeg`; enhancement core adds `curl`, `ca-certificates`.
- Bootstrap: `uv`, `comfy-cli`, `pip`, `setuptools`, `wheel`; configured CUDA Torch/torchvision/torchaudio.
- ComfyUI's `/comfyui/requirements.txt`, installed into `/opt/venv` in the shared final stage and enhancement overlay.
- Worker: `runpod`, `requests`, `websocket-client`, unpinned in Docker. Repository `requirements.txt` separately requests `runpod~=1.7.12`; it is not a complete Docker environment lock and is not used by that Docker install command.
- Every installed custom node's requirements when present; enhancement overlay adds `piexif`, `ultralytics`, `segment-anything`, `dill`.
- [Nunchaku node requirements at v1.2.1](https://github.com/nunchaku-ai/ComfyUI-nunchaku/blob/v1.2.1/requirements.txt): `diffusers>=0.35`, `transformers>=4.54`, `sentencepiece`, `protobuf`, `huggingface_hub>=0.34`, `tomli`, `peft>=0.17`, `accelerate>=1.10`, `insightface`, `opencv-python`, `facexlib`, `onnxruntime`, `timm`, plus the compiled Nunchaku wheel.
- [QwenVL current requirements](https://github.com/1038lab/ComfyUI-QwenVL/blob/main/requirements.txt): `transformers`, `torch`, `huggingface-hub`, `hf_xet`, `psutil`, `numpy`, `Pillow`, `opencv-python`, `bitsandbytes`, `accelerate`; vision GGUF separately uses llama-cpp-python. The manifest notes Transformers >=4.57 for the Qwen3-VL HF backend; this graph uses GGUF.

There is no complete pinned Python lock. Binary availability can change; the runtime base lacks a full compiler/CUDA development toolchain. If an upstream package requires a source build, select a compatible wheel or explicitly add its documented build dependencies. Do not assume arbitrary pip upgrades remain Nunchaku-compatible.

`start.sh` attempts to preload `libtcmalloc`, but this target does not explicitly install its OS package. An empty preload is not itself a missing workflow dependency; add/verify the allocator separately if desired.

## 6. Clone and configure

```bash
git clone https://github.com/MomenSirri/worker-comfyui-momen.git
cd worker-comfyui-momen
cp .env.example .env
```

PowerShell: `Copy-Item .env.example .env`. Populate tokens without committing `.env`. This target downloads its models; local LoRA files used by other targets are not required.

### Build variables

| Variable | Purpose/default |
| --- | --- |
| `HUGGINGFACE_ACCESS_TOKEN` | Optional/gated download authorization; empty by default. |
| `CIVITAI_API_TOKEN` | Optional Civitai token; may be needed for bundled Kreamania. |
| `KREAMANIA_FP8_SHA256` | Optional trusted hash; empty skips integrity verification. Repository supplies no expected hash. |
| `COMFYUI_VERSION` | `latest`; use a tested comfy-cli-supported version for a controlled build. |
| `MODEL_TYPE` | Must be `enhance` for a fresh enhancement core. |
| `ENHANCE_CORE_IMAGE` | Default `final-enhance-core` builds the in-file core; a compatible image reference reuses that core. |
| `DOCKERHUB_REPO`, `RELEASE_VERSION` | Bake namespace/tag; defaults `momensirribrick`, `latest`. |
| `ESSENTIALS_COMMIT`, `WAS_COMMIT` | Pinned defaults in the node table; Docker build arguments. |
| `QWENVL_COMMIT`, `TOOLING_COMMIT`, `POST_COMMIT`, `CROP_STITCH_COMMIT`, `KJNODES_COMMIT` | Moving defaults; override with tested commits using Docker arguments or Bake `--set`. |
| `NUNCHAKU_COMFYUI_TAG`, `NUNCHAKU_WHEEL_URL` | Node/backend selections described above. |
| `LLAMA_CPP_PYTHON_REPO`, `LLAMA_CPP_PYTHON_TAG`, `LLAMA_CPP_PYTHON_PYTAG` | Vision wheel selection described above. |
| `FLUXMANIA_SVDQ_INT4_URL` | Overlay INT4 download source from the model table. |

Compose loads `.env` at runtime; Docker does not automatically populate build arguments from it. Load its values into the current shell:

```bash
set -a
source .env
set +a
export RELEASE_VERSION=v05
```

PowerShell:

```powershell
Get-Content .env | ForEach-Object {
    if ($_ -notmatch '^\s*(#|$)') {
        $name, $value = $_ -split '=', 2
        [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), 'Process')
    }
}
$env:RELEASE_VERSION = 'v05'
```

The existing build uses token arguments and may print token-bearing Civitai URLs; handle logs/cache accordingly. It does not use BuildKit secret mounts. Runtime inference needs no download credentials when all files are present.

## 7. Build

From the repository root, Bash/WSL:

```bash
docker buildx build --platform linux/amd64 --load \
  --target final-enhance -t momensirribrick/general-enhancement:v05 \
  --build-arg BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04 \
  --build-arg COMFYUI_VERSION=latest \
  --build-arg CUDA_VERSION_FOR_COMFY= \
  --build-arg ENABLE_PYTORCH_UPGRADE=true \
  --build-arg PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128 \
  --build-arg PYTORCH_VERSION=2.10.0 \
  --build-arg TORCHVISION_VERSION=0.25.0 \
  --build-arg TORCHAUDIO_VERSION=2.10.0 \
  --build-arg MODEL_TYPE=enhance \
  --build-arg HUGGINGFACE_ACCESS_TOKEN \
  --build-arg CIVITAI_API_TOKEN \
  --build-arg KREAMANIA_FP8_SHA256 .
```

For PowerShell replace `\` continuations with backticks or use this one-line Bake equivalent after setting `RELEASE_VERSION`:

```powershell
docker buildx bake -f docker-bake.hcl enhance --set enhance.args.PYTORCH_VERSION=2.10.0 --set enhance.args.TORCHVISION_VERSION=0.25.0 --set enhance.args.TORCHAUDIO_VERSION=2.10.0 --load
```

Invoke only `enhance`, not Bake's default group of unrelated builds. Default stage chain: `base → downloader → final → final-enhance-core → final-enhance`. Downloaded models are copied into the final image.

### Required build context/image files

Keep these repository paths: `Dockerfile`, `scripts/comfy-node-install.sh`, `scripts/comfy-manager-set-mode.sh`, `src/extra_model_paths.yaml`, `src/start.sh`, `src/network_volume.py`, `handler.py`, `test_input.json`, and `custom_nodes/momi_gpu_model_selector/`. Linux scripts need LF endings; CRLF in `/start.sh` can prevent startup. `.dockerignore` controls local asset inclusion.

The final overlay installs dependency fixes, INT4 Fluxmania, the local GPU selector, CropAndStitch, and KJNodes. Worker files are copied from the small `runtime-files` stage last for fast handler rebuilds. The workflow and test helper are host-side artifacts, **not baked into the image**; submit the graph with each request. The baked `test_input.json` is a generic example, not an enhancement test.

### Reuse a heavy core

```bash
export RELEASE_VERSION=v05
docker buildx bake -f docker-bake.hcl enhance-core --set enhance-core.args.PYTORCH_VERSION=2.10.0 --set enhance-core.args.TORCHVISION_VERSION=0.25.0 --set enhance-core.args.TORCHAUDIO_VERSION=2.10.0 --load
docker buildx bake -f docker-bake.hcl enhance --set enhance.args.ENHANCE_CORE_IMAGE=momensirribrick/general-enhancement:core-v05 --load
```

To publish, `docker login`, set `DOCKERHUB_REPO` to a namespace you control, and use `--push` instead of `--load`. Referencing a pushed core on another machine skips its heavy rebuild. Core models, ComfyUI, nodes, Torch and llama versions remain those in that image; new core arguments passed only to the overlay do not update them. Use a known digest when reproducing a release.

## 8. Run locally or on RunPod

### Local Docker

Bash/WSL:

```bash
docker run -d --name general-enhancement --gpus all \
  -e SERVE_API_LOCALLY=true -e COMFY_LOG_LEVEL=INFO \
  -p 127.0.0.1:8000:8000 -p 127.0.0.1:8188:8188 \
  momensirribrick/general-enhancement:v05
docker logs -f general-enhancement
```

PowerShell:

```powershell
docker run -d --name general-enhancement --gpus all -e SERVE_API_LOCALLY=true -e COMFY_LOG_LEVEL=INFO -p 127.0.0.1:8000:8000 -p 127.0.0.1:8188:8188 momensirribrick/general-enhancement:v05
```

For faithful conditioning add the embeddings mount above. Optionally mount a host output directory at `/comfyui/output` to persist results. Uploads are placed in `/comfyui/input`. An empty mount over `/comfyui/models` hides bundled weights.

Port 8000 is the worker API; 8188 is ComfyUI. `SERVE_API_LOCALLY=true` starts ComfyUI with `--listen` and the RunPod SDK with `--rp_serve_api --rp_api_host=0.0.0.0`. Handler access to ComfyUI is hardcoded to `127.0.0.1:8188`. Local API routes include `/run`, `/runsync`, `/health`, and the installed SDK's job-status routes.

### Compose

The base Compose currently selects a Flux2-Klein image. Use the enhancement override, whose filename says v04 but whose image is v05:

```bash
docker compose -f docker-compose.yml -f docker-compose.enhance-v04.test.override.yml config
docker compose -f docker-compose.yml -f docker-compose.enhance-v04.test.override.yml up -d
```

Inspect resolved config locally: confirm enhancement image, GPU reservation, and host ports. Port lists can merge: the override adds 8001/8189 alongside base 8000/8188. Set helper URLs to the published ports. Compose requires `.env`, uses `pull_policy: never` (build/pull first), and mounts `./data/comfyui/output` and `./data/runpod-volume`. Avoid conflicts with another container using those ports.

### RunPod Serverless

Push the final image, create a GPU Serverless endpoint using its tag/digest, and set runtime variables there. Leave `SERVE_API_LOCALLY` unset/false. Submit the same `input.workflow` and `input.images` to the endpoint's `/run` or `/runsync` with RunPod authorization. For long jobs use asynchronous `/run` and poll status; configure sufficient platform execution timeouts.

### Runtime configuration

| Variable | Default / purpose |
| --- | --- |
| `SERVE_API_LOCALLY` | Unset/false; `true` for local API. |
| `COMFY_LOG_LEVEL` | `DEBUG`; `INFO` is less verbose. |
| `COMFY_API_AVAILABLE_INTERVAL_MS`, `COMFY_API_AVAILABLE_MAX_RETRIES` | `250`, `600`; readiness checks. |
| `COMFY_API_HEALTH_PATH` | `/object_info`. |
| `WEBSOCKET_RECONNECT_ATTEMPTS`, `WEBSOCKET_RECONNECT_DELAY_S` | `5`, `3`; reconnect controls. |
| `WEBSOCKET_TRACE` | `false`; detailed websocket logging. |
| `ENABLE_COMFY_RUNTIME_LOG_BRIDGE`, `COMFY_RUNTIME_LOG_PATH` | `true`, `/comfyui/user/comfyui.log`; progress parsing. |
| `PROGRESS_UPDATE_MIN_INTERVAL_S` | `0.75`; progress throttling. |
| `ENHANCEMENT_TRACK_NODE_ID` | Empty/automatic; optional progress tracking override. |
| `ENHANCE_CYCLE_COMPLETE_RATIO` | `0.85`; progress accounting. |
| `REFRESH_WORKER`, `REFRESH_WORKER_ON_FAILURE` | `false`, `true`; worker refresh behavior. |
| `FAIL_FAST_ON_EXECUTION_ERROR` | `true`. |
| `NETWORK_VOLUME_DEBUG` | `false`; model path diagnostics. |
| `COMFY_ORG_API_KEY` | Optional; graph has no Comfy.org paid API nodes. |
| `BUCKET_ENDPOINT_URL`, `BUCKET_ACCESS_KEY_ID`, `BUCKET_SECRET_ACCESS_KEY` | Optional storage output; otherwise base64. See [configuration](docs/configuration.md). |

Startup sets ComfyUI-Manager offline through the helper script. This does not block downloads by other nodes. Package all dependencies in advance when runtime access is restricted.

### Network volume paths

[src/extra_model_paths.yaml](src/extra_model_paths.yaml) maps `/runpod-volume/models/` categories `checkpoints`, `clip`, `clip_vision`, `configs`, `controlnet`, `embeddings`, `loras`, `upscale_models`, `vae`, and `unet`. It does **not explicitly map** enhancement categories `text_encoders`, `diffusion_models`, `llm/GGUF`, `sams`, or `ultralytics`. Bundled local files work normally; migrating everything to a volume requires explicit extra-path/custom-node setup. Qwen path integration depends on node version. Linux `llm` and `LLM` differ; this enhancement build uses lowercase `llm`.

## 9. Validate and test

Wait for startup and inspect logs for failed custom-node imports. Then:

```bash
curl http://127.0.0.1:8188/object_info
curl http://127.0.0.1:8000/health
docker exec general-enhancement /opt/venv/bin/python -c "import torch, nunchaku, llama_cpp; print(torch.__version__, torch.version.cuda, torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
docker exec general-enhancement /opt/venv/bin/python -m pip check
docker exec general-enhancement /opt/venv/bin/python -m pip freeze
docker exec general-enhancement git -C /comfyui rev-parse HEAD
```

Use `curl.exe` in PowerShell when `curl` is aliased. Imports and `pip check` help diagnose environment consistency but do not validate GPU inference. Confirm final Torch/CUDA match the wheel even if a build previously succeeded.

### Prepare a payload and preflight

Original node `81` expects `pasted/image (150).png`, which is not supplied. The [test helper](scripts/test-general-enhancement.py) replaces this with an uploaded filename and writes `general-enhancement-input.json`. It checks `/object_info` for all graph classes, required inputs and literal dropdown values, including selected models/enums. It needs no third-party host packages.

With original embeddings and a suitable FP4 GPU:

```bash
python scripts/test-general-enhancement.py /path/to/photo.png
python scripts/test-general-enhancement.py /path/to/photo.png --run
```

For non-Blackwell add `--int4`. For a test without the missing embeddings add `--without-embeddings`:

```bash
python scripts/test-general-enhancement.py /path/to/photo.png --int4 --without-embeddings --run
```

Windows:

```powershell
python scripts/test-general-enhancement.py 'D:\Pictures\photo.png' --int4 --without-embeddings --run
```

URL input with the updated handler:

```bash
python scripts/test-general-enhancement.py https://example.com/photo.png --without-embeddings --run
```

Replace that URL with an actual accessible image. HTTP(S) public/signed URLs require no extra headers; downloads follow redirects, have a 50 MiB limit, and use 10-second connect/60-second read timeouts. Content type must be `image/*` or `application/octet-stream`. Raw base64/data URIs remain supported. URL support applies to worker `input.images`: internal `ETN_LoadImageBase64` nodes still consume graph-generated base64, not URLs.

For Compose override ports add `--comfy-url http://127.0.0.1:8189 --worker-url http://127.0.0.1:8001`. The execution HTTP timeout defaults to 3600 seconds (`--timeout` overrides it); this cannot extend SDK/platform execution limits. Preflight does not load weights or validate embeddings, projectors, all linked types, or GPU kernels. Resolve node-version/input mismatches deliberately before execution.

### Execute manually and inspect output

After generating the payload:

```bash
curl -X POST http://127.0.0.1:8000/runsync \
  -H 'Content-Type: application/json' \
  --data-binary @general-enhancement-input.json
```

With `--run`, the helper saves `general-enhancement-result.json`. **This checkout's handler** returns `output.status="success"` and `output.message` as a list of base64 strings or storage URLs. The main README's `output.images` example does not match this handler's current contract. Inspect both job/worker statuses; HTTP success alone is insufficient. PNGs also appear in `/comfyui/output`.

Decode base64 outputs with host Python:

```python
import base64, json
from pathlib import Path
result = json.loads(Path("general-enhancement-result.json").read_text(encoding="utf-8"))
for index, data in enumerate(result["output"]["message"]):
    if data.startswith(("http://", "https://")):
        print(data)
    else:
        Path(f"enhanced-{index}.png").write_bytes(base64.b64decode(data))
```

Use a representative photograph: tiny samples may bypass person/face detections. The graph resizes to a 1280–5120 range in its detailer path, uses roughly 900-pixel tile sizing, 25-step Flux passes, 30-step SD refinement, and retains Qwen in memory. Resolution, tile count and detections affect time/VRAM. Test one request at a time. Reducing dimensions/steps for a smoke test changes the workflow and does not benchmark the original.

## 10. Limitations and troubleshooting

| Symptom / gap | Explanation / action |
| --- | --- |
| Generic `test_input.json` cannot load `flux1-dev-fp8.safetensors` | This sample's checkpoint is not bundled in enhancement. Use the dedicated v1.19 helper. |
| Missing EasyNegative/epiCNegative | Supply originals or explicitly remove their references using the helper adaptation; epiCNegative's original source/version remains unknown. |
| Unsupported FP4 GPU | Graph bypasses the bundled selector. Adapt node `40` to INT4 on compatible hardware. |
| Nunchaku import/kernel/undefined-symbol failure | Check final Torch 2.10 / cu128 / Python 3.12 and wheel ABI after node installs. |
| Qwen vision handler/projector failure | Check GGUF plus F16 projector, case-sensitive paths, and configured vision wheel. Build-time source checks are not CUDA inference tests. |
| Unknown `GetImageSize` / changed required inputs | ComfyUI/node branches move. Use preflight and pin a compatible set; inspect import errors. |
| Models absent on network volume | Check extra-path coverage/case and mounts hiding local bundled files. |
| HF/Civitai download failure | Check access/tokens, license acceptance, availability and disk. Unused Kreamania can still stop the build. Only its optional checksum is configurable; other assets are not hash-pinned. |
| Input image missing | Replace node `81`'s local path with the uploaded name; helper does this. |
| OOM/long runs | Several high-resolution passes, retained Qwen and detections add work. Inspect offloading/logs; deliberately tune resolution/steps/model retention if needed. |
| UI import unavailable | Supplied graph is API format; submit via API or obtain a separate UI-format export. |

No private service dependency is identified in the graph. Internal project components are the worker/entrypoint, path configuration and bundled local GPU selector. Some nodes are disconnected from final output (for example `88`); preflight conservatively checks the entire graph. Storage and Comfy.org integrations are optional.

The project does not provide a validated ComfyUI/node lock, original embedding hashes, complete GPU matrix, or measured resource minimum. Those are reproducibility gaps, not details that can be inferred safely. Record the successful environment and image digest before distributing a reproducible release claim.

## Audit sources

- Project: [Dockerfile](Dockerfile), [Bake configuration](docker-bake.hcl), [workflow](workflows/general-enhancement/workflow_api_flux_dev_1.19.json), [handler](handler.py), [entrypoint](src/start.sh).
- Registration checks: [Essentials pinned image nodes](https://github.com/cubiq/ComfyUI_essentials/blob/9d9f4bedfc9f0321c19faf71855e228c93bd0dc9/image.py), [KJNodes](https://github.com/kijai/ComfyUI-KJNodes), [CropAndStitch](https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch), [ComfyUI image extras](https://github.com/Comfy-Org/ComfyUI/blob/master/comfy_extras/nodes_images.py), [Nunchaku v1.2.1 Flux loader](https://github.com/nunchaku-ai/ComfyUI-nunchaku/blob/v1.2.1/nodes/models/flux.py), and repositories linked above.
- [Vision llama-cpp release](https://github.com/JamePeng/llama-cpp-python/releases/tag/v0.3.30-cu128-Basic-linux-20260302), manifests and model download links in the preceding sections.
