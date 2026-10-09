# General Enhancement — build and setup

This guide covers Bake target `enhance`, Docker target `final-enhance`, and image `momensirribrick/general-enhancement`. The published release is `v07`, which the enhancement Compose override runs; `command.txt` uses `v08` for the next one. Bake tags the image `latest` unless `RELEASE_VERSION` is set. Image tags are project releases, not ComfyUI versions.

## Workflow audited

Dependencies were identified from the actual [API workflow v1.19](workflows/general-enhancement/workflow_api_flux_dev_1.19.json), supplied from `workflow_api_flux_dev_1.19 .json`. The repository copy preserves the source bytes: 86 nodes, 55 distinct node classes, SHA256 `b64fd473e3ec6b6cc2707e1c9ae664aed4c55cad605ed10adebd07de6f42f1fd`.

The graph performs Fluxmania person/face detailing, Qwen image description, tiled SD 1.5 refinement, ReFocus processing, Flux tile refinement, and crop/stitch output. Node `83` is the final `SaveImage`. This is an API-format graph, not a UI graph with positions/widgets: execute it through the worker API. A UI-format authoring version is not supplied.

This document separates graph dependencies from additional assets installed by the target.

### The graph AZ-AI submits in production

The AZ-AI backend does not submit the file above. It builds each request from its own template, `backend/libs/integrations/src/runpod/workflows/workflow_api_flux_dev_1.19 .json` in the backend repository (139 nodes, 51 classes, SHA256 `5a82a05b72fcfb720d7407228407121af4c07683e92432e8c355367b5c3ad5a4` when this image was built), and keeps only the nodes its output node `647` depends on. That graph is a different revision of the same pipeline, and the image has to serve both:

| | Repository graph v1.19 | AZ-AI backend graph |
| --- | --- | --- |
| Input | `LoadImage` node `81` | Node `72`: inline base64 in `ETN_LoadImageBase64`, or `LoadImage` of `input_image.png` uploaded from `input.images` (base64 or URL) |
| Output | `SaveImage` node `83` | `SaveImage` node `647` |
| Fluxmania loader | Node `40` | Node `209`, also fixed to the FP4 file |
| Extra node classes | `ImagePass`, `ImageResizeKJv2`, `InpaintCropImproved`, `InpaintStitchImproved`, `easy imageListToImageBatch`, core custom-sampler nodes | `Context (rgthree)`, `Context Switch (rgthree)`, `Mask Crop Region` (WAS), `ImageCrop+`, `SimpleMathInt+`, `NunchakuFluxLoraStack` |
| Extra models | none | `flux-RealismLora.safetensors`, `boreal-flux-dev-lora-v04_1000_steps.safetensors` |
| Stages | One fixed pipeline | General (SD 1.5 + Qwen, no Flux), Advanced Detailer (Flux), Body/Face (Flux + detectors), chained per request |

All other models, including the two unresolved negative embeddings, are shared. Sections 3 and 4 list the union.

### What was verified

Built and run on 2026-10-03 with Docker Desktop 29.5.2 (WSL2) and an RTX 3060 12 GB. Image `momensirribrick/general-enhancement:v07`, local ID `sha256:f4e7b4d677269fa4426cca69224b43dd743770e340e182e700fff3a920489566`, 33.8 GB (the published `v06` is 66.1 GB). The full package list is in [pip-freeze-v07.txt](workflows/general-enhancement/pip-freeze-v07.txt).

- **Build.** `final-enhance` with the command in section 7, no tokens. The build-time gates passed: one Python environment, every custom node imports, PyTorch matches the Nunchaku wheel, all 16 models match `models.sha256`, and the Qwen files are where the node resolves them.
- **Startup.** ComfyUI 0.38.0 starts in about 20 s with 14 custom-node packages and no import failure. PyTorch, Nunchaku and llama-cpp all see the GPU; llama-cpp reports GPU offload and both Qwen vision handlers. `pip check` reports no broken requirements.
- **URL inputs**, called against the running container: a signed-style HTTP URL, `application/octet-stream`, a 302 redirect and a public HTTPS URL are stored byte-for-byte; an HTML page, an empty body, a 51 MiB body, HTTP 404 and an unreachable host are rejected with no URL in the message; base64 and data URIs still work.
- **Jobs.** Requests for the AZ-AI graph were generated with the backend's own `buildEnhancementWorkflow` and submitted to `/runsync`. The final round ran on a Docker network with no internet access and an S3-compatible mock as the output bucket, so every result came back as `output.images[0]` with `type: "s3_url"` and was fetched from the bucket:

| Graph and input | Result | Time on the RTX 3060 |
| --- | --- | --- |
| AZ-AI General, 768×512, URL | Correct, 768×512 | 78–79 s on a cold worker |
| AZ-AI General, 768×512, inline base64 | Correct, 768×512 | 68 s |
| AZ-AI Body/Face, 1280×720 with two people, URL | Correct, 1280×720; five detailer passes | 304–327 s |
| AZ-AI Advanced Detailer, 2304×1536, URL | Correct, 2304×1536 | 217–240 s |
| Repository v1.19, 1280×720, URL (`--int4 --without-embeddings`) | Correct, 2276×1280 | 269 s |
| AZ-AI General, URL that returns 404 | Job `FAILED` in 0.2 s; details say `HTTP 404` only | — |

No model was downloaded at run time, and the input URL's query string appears nowhere in the worker log.

Not verified, or found wrong:

- **FP4 on a Blackwell GPU.** Both graphs select `svdq-fp4_r32-fluxmania-legacy.safetensors`. Every Flux job here used the INT4 file instead, because the RTX 3060 cannot run FP4. Run one real job per input mode on the production GPU type before moving traffic.
- **AZ-AI Advanced Detailer on inputs under 2048 px.** The graph upscales the image to 2048 px and then crops it with coordinates computed at the original size, so the result is an enlarged top-left crop (37.5% of a 768 px image, 62.5% of a 1280 px one). The same happens with all three stages enabled. It is a defect in the backend's workflow template: the stage is correct for a 2304×1536 input, and v1.19 does not have it.
- **A real R2 bucket and real signed R2 URLs.** The S3 path was exercised against a mock, the URL path against a local HTTP server and one public HTTPS URL.
- **VRAM headroom.** Usage peaked at 11.9 of 12.3 GB. Once, when the Qwen model was reloaded while Flux weights from the previous job were still cached, llama-cpp reported `ggml-cuda.cu:97: CUDA error` (no further detail was logged) and aborted the process. ComfyUI died, the handler returned a failed job and asked for a worker refresh. The likely cause is memory exhaustion on this 12 GB card: the same job order passed when repeated on a fresh container. It has not been tested on a larger GPU.
- **Negative embeddings.** Neither file is bundled. ComfyUI logs `embedding:easynegative, does not exist, ignoring`. `epiCNegative` is never looked up in either graph: its token is written `,embedding:epiCNegative,`, and ComfyUI only treats a word as an embedding when it starts with `embedding:`.
- **Other Docker targets.** The base and downloader stages are shared; only `final-enhance` and `final-enhance-core` were built.

### Build changes after `v07` (2026-10-05)

The Dockerfile and Bake file were reworked after `v07` was published. **No image has been built with its models or published from this state yet.**

What changed for this image:

- Everything `v07` resolved at build time is now a default: ComfyUI 0.38.0, uv 0.12.23, comfy-cli 1.22.0, the five registry nodes, the worker's `requirements.txt`, and all other Python packages through `constraints/general-enhancement-v07.txt`.
- The llama-cpp wheel is downloaded by URL and checked against its SHA256, instead of being looked up through the GitHub API.
- Tokens are BuildKit secrets, not build arguments.
- The models are copied as one layer per model folder instead of one 20.8 GB layer.
- The repeated installation blocks moved to `scripts/build/`, and the registry installer now verifies its result.

Checked on 2026-10-05, with Docker Desktop 29.5.2:

- `docker buildx build --check .` reports no warnings, `docker buildx bake --print` resolves all 14 targets, and the 20 unit tests pass.
- **A complete `enhance` build without the model downloads** (`MODEL_TYPE=base`, a small file in place of the INT4 model, and a checksum list that names one small file). Every step ran: the pinned registry and Git nodes, the Nunchaku wheel, the llama-cpp wheel with a matching SHA256, the custom-node import check and the PyTorch/Nunchaku check. `pip check` reports no broken requirements.
- **The package list of that build equals `pip-freeze-v07.txt` in 297 of 298 packages.** The exception is `posthog` 7.63.0 instead of 7.62.1: a comfy-cli dependency, installed before the constraints file applies.
- With the real Qwen path check and no models, the last step fails and names the missing file, as intended.

Not checked:

- **A build with the models.** The per-folder model layers were only built from empty folders; the download steps, their retry settings and the real checksum list did not run.
- **A GPU job, and a push or pull** of the new layer layout.
- **A build with a token.** The secret mechanism was tested with a stand-in build only.

## 1. Prerequisites

- NVIDIA CUDA GPU and a host driver compatible with CUDA 12.8. The supplied graph selects Blackwell FP4 weights; compatible non-Blackwell GPUs need the INT4 adaptation below.
- Docker Engine/Desktop with BuildKit/Buildx and GPU access. On Linux configure [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html). On Windows use Linux containers with [Docker Desktop WSL2 GPU support](https://docs.docker.com/desktop/features/gpu/).
- Git and build-time access to GitHub, Hugging Face, Civitai, PyPI, the PyTorch wheel index, and Ubuntu repositories. Host Python 3.10+ is needed only for the included standard-library test helper; the container uses Python 3.12.
- Sufficient disk for several large diffusion models, Qwen, the final image, and intermediate BuildKit layers. The `v07` image is 33.8 GB, and while it builds the model and environment layers also exist in the build cache; Docker Desktop's data disk grew by about 40 GB over the builds recorded here. All graphs ran on a 12 GB RTX 3060 with the INT4 weights; no minimum RAM/VRAM requirement has been measured beyond that.
- No token is needed for the default build. Docker Desktop's default setting keeps only 20 GB of build cache (`builder.gc.defaultKeepStorage` under Settings → Docker Engine), so after a failed or finished build the large cached layers are pruned and the next build downloads the models and PyTorch again. Raise that value to about 60 GB if the disk allows, or tag the heavy core once (see "Reuse a heavy core") before iterating on the overlay.

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
| Python | 3.12.3; the only environment is `/opt/venv` (`VIRTUAL_ENV` is set so comfy-cli installs there too). Use `/opt/venv/bin/python -m pip`. |
| ComfyUI | Validated with **v0.38.0** (`6b747c04`), which is what `latest` resolved to on 2026-10-03. Since 2026-10-05 `0.38.0` is the default of the Dockerfile and of Bake's `COMFYUI_VERSION`. Another version must provide every core class in the graphs, including `GetImageSize` and Flux sampling, and support the custom-node APIs. |
| PyTorch | **2.10.0+cu128**, torchvision 0.25.0, torchaudio 2.10.0, pinned in the Bake `enhance` targets and required by the Nunchaku wheel (Torch 2.10, CUDA 12.8, Python 3.12). The newest cu128 PyTorch is already 2.11, so an unpinned build fails the final check. ComfyUI 0.38.0 logs that cu130 is needed for its optimized CUDA operations; with cu128 it uses its standard PyTorch path, and no Nunchaku or llama-cpp wheel pairing for cu130 has been validated here. |
| ComfyUI-Nunchaku | `NUNCHAKU_COMFYUI_TAG=v1.2.1`. |
| Nunchaku backend | `1.2.1+cu12.8torch2.10`, `cp312`, `linux_x86_64`, from the [v1.2.1 release](https://github.com/nunchaku-ai/nunchaku/releases/tag/v1.2.1). Match node/backend, Torch, CUDA, Python ABI, and quantization. |
| llama-cpp-python | Repository `JamePeng/llama-cpp-python`, release `v0.3.30-cu128-Basic-linux-20260302`, wheel `llama_cpp_python-0.3.30+cu128.basic-cp312-cp312-linux_x86_64.whl`. [scripts/build/install-llama-vision.sh](scripts/build/install-llama-vision.sh) downloads that wheel by URL, checks its SHA256, and checks the source for `Qwen3VLChatHandler` and `Qwen25VLChatHandler`; it does not test CUDA inference during the build. |

Do not select an arbitrary old ComfyUI or upgrade Torch independently. The `v07` build resolved rgthree-comfy 1.0.2608210019, comfyui-custom-scripts 1.2.5, comfyui-impact-pack 8.28.3, comfyui-impact-subpack 1.3.5 and comfyui-easy-use 1.3.6; since 2026-10-05 those versions are the defaults of the registry installation. Other versions in `v07`: runpod 1.12.0, numpy 2.3.2, transformers 5.18.0, diffusers 0.40.0, ultralytics 8.4.172, OpenCV 5.0.0, llama-cpp-python 0.3.30. `pip check` reports no broken requirements. After changing any of these, record Git revisions, `pip freeze` and the image digest again.

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
| Flux autoencoder (the FLUX.1-schnell `ae.safetensors`) | `41` | `/comfyui/models/vae/ae.safetensors` | With `HUGGINGFACE_ACCESS_TOKEN`: gated [black-forest-labs/FLUX.1-schnell](https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors). Without a token: the same file from [Comfy-Org's ungated repackage](https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors). The build checks SHA256 `afc8e282…529e38` either way. | Yes |
| XLabs Flux Realism LoRA, renamed | AZ-AI graph `640` | `/comfyui/models/loras/flux-RealismLora.safetensors` | [XLabs-AI/flux-RealismLora/lora.safetensors](https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors) | Yes |
| Boreal Flux-dev LoRA v04, 1000 steps | AZ-AI graph `640` | `/comfyui/models/loras/boreal-flux-dev-lora-v04_1000_steps.safetensors` | [kudzueye/Boreal](https://huggingface.co/kudzueye/Boreal/resolve/main/boreal-flux-dev-lora-v04_1000_steps.safetensors) | Yes |
| Qwen3-VL 4B Instruct Q8_0 GGUF | `33` | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/Qwen3VL-4B-Instruct-Q8_0.gguf` | [Qwen/Qwen3-VL-4B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q8_0.gguf) | Yes |
| Matching Qwen3-VL 4B Instruct F16 vision projector | Implicit for `33` | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-F16.gguf` | [Qwen F16 mmproj](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-F16.gguf) | Yes |
| 1x ReFocus V3 | `19` | `/comfyui/models/upscale_models/1x-ReFocus-V3.pth` | [notkenski/upscalers](https://huggingface.co/notkenski/upscalers/resolve/main/1x-ReFocus-V3.pth) | Yes |
| SAM ViT-B checkpoint 01ec64 | `46`, `55` | `/comfyui/models/sams/sam_vit_b_01ec64.pth` | [Meta SAM](https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth) | Yes |
| Face YOLOv8m bbox | `56` | `/comfyui/models/ultralytics/bbox/face_yolov8m.pt` | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt) | Yes |
| Person YOLOv8m segmentation | `42`, `43` | `/comfyui/models/ultralytics/segm/person_yolov8m-seg.pt` | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt) | Yes |
| Face YOLOv8m segmentation, `_60` artifact | `57` | `/comfyui/models/ultralytics/segm/face_yolov8m-seg_60.pt` | [hben35096/assets, yolo8 release](https://github.com/hben35096/assets/releases/download/yolo8/face_yolov8m-seg_60.pt) | Yes |
| EasyNegative embedding | `27` prompt | `/comfyui/models/embeddings/easynegative.safetensors` | [EvilEngine/easynegative mirror](https://huggingface.co/EvilEngine/easynegative/resolve/main/easynegative.safetensors); [source attribution](https://huggingface.co/EvilEngine/easynegative) | **No** |
| epiCNegative embedding | `27` prompt | `/comfyui/models/embeddings/epiCNegative.safetensors`, or original compatible `.pt` with this stem | **Exact original version/source is not recorded and was not verified. Obtain the original from the workflow owner.** | **No** |

Node `37` has `strength_model=0` but `strength_clip≈1`, so its LoRA is still a dependency. Node `33` names only the GGUF; the [QwenVL model configuration](https://github.com/1038lab/ComfyUI-QwenVL/blob/main/gguf_models.json) identifies its matching F16 projector.

The two Flux LoRAs are not in v1.19 but are required by the AZ-AI backend graph: its `NunchakuFluxLoraStack` node `640` loads them at strengths 0.85 and 0.8. See [the production graph](#the-graph-az-ai-submits-in-production).

Every bundled file is listed with its SHA256 in [models.sha256](workflows/general-enhancement/models.sha256). The last build step runs `sha256sum --check` on that list, so a missing, truncated or silently replaced upstream file fails the build. Fourteen of the hashes were taken from the Hugging Face file metadata, the SAM hash from two independent mirrors, and the `face_yolov8m-seg_60.pt` hash from the release download itself.

### Missing embeddings: faithful setup or explicit adaptation

For faithful conditioning supply both embeddings with exact stems `easynegative` and `epiCNegative`; preserve case on Linux. Names alone do not identify their original versions/hashes. The EasyNegative mirror is a download source, not proof of the original artifact. epiCNegative's provenance remains unresolved.

As both graphs are written today, only `easynegative` is actually looked up. The negative prompt reads `embedding:easynegative, ,embedding:epiCNegative, …`; ComfyUI splits it on spaces and treats a word as an embedding only when it starts with `embedding:`, so `,embedding:epiCNegative,` is encoded as plain text and a bundled `epiCNegative` file would not be loaded. Supplying `easynegative` alone changes the output compared with the published images, which do not have it either.

Mount a host `embeddings/` folder to `/comfyui/models/embeddings`, or bake a child image:

```dockerfile
FROM momensirribrick/general-enhancement:v07
COPY embeddings/ /comfyui/models/embeddings/
```

Place files in a top-level `embeddings/` directory for this child build: the existing `.dockerignore` excludes most local `models/` paths. Merely placing files under local `models/embeddings` will not package them. Runtime mount option, added to `docker run`:

```bash
--mount type=bind,src="$PWD/embeddings",dst=/comfyui/models/embeddings,readonly
```

Alternatively the helper's `--without-embeddings` removes the two `embedding:` references from a generated request. **This changes negative conditioning** and does not reproduce the original exactly. It leaves the source workflow intact and lets you test the remaining graph without the unresolved epiCNegative file. Missing embeddings may produce warnings rather than hard failures, so job success alone does not prove they loaded.

### Optional assets that no enhancement graph selects

Neither v1.19 nor the AZ-AI graph references these, so the build leaves them out by default. `--build-arg ENHANCE_EXTRA_MODELS=true` (Bake: `ENHANCE_EXTRA_MODELS=true` in the environment) bundles them again, which adds about 19 GB and needs a Civitai token for Kreamania. They are not in `models.sha256`.

| Asset | Exact destination | Source |
| --- | --- | --- |
| Nunchaku FLUX.1-dev FP4 rank 32 | `/comfyui/models/diffusion_models/svdq-fp4_r32-flux.1-dev.safetensors` | [nunchaku-ai/nunchaku-flux.1-dev](https://huggingface.co/nunchaku-ai/nunchaku-flux.1-dev/resolve/main/svdq-fp4_r32-flux.1-dev.safetensors) |
| Fluxmania Kreamania FP8, Civitai version ID `2106807` | `/comfyui/models/diffusion_models/fluxmania_kreamania.safetensors` | [model page](https://civitai.com/models/778691/fluxmania), [exact API download](https://civitai.com/api/download/models/2106807?type=Model&format=SafeTensor&size=full&fp=fp8) |
| Qwen3-VL 4B Instruct Q8_0 projector | `/comfyui/models/llm/GGUF/Qwen/Qwen3-VL-4B-Instruct-GGUF/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf` | [Qwen Q8_0 mmproj](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf) |

SeedVR2, ControlNet, IPAdapter, and Flux2-Klein are not referenced by either graph. Their unrelated Docker stages/local model files are not needed for `final-enhance`.

## 4. Custom nodes

The target installs these automatically. For manual setup clone each repository under `/comfyui/custom_nodes/`, check out the listed revision, install its `requirements.txt` when present using the runtime Python, and restart ComfyUI. Registry nodes are installed at a pinned version (`name@version`), and the build fails when a requested node or version is not on disk afterwards. Git nodes are fetched shallowly at the pinned commit by [scripts/build/node-git.sh](scripts/build/node-git.sh); a commit argument also accepts a branch or tag name that exists in that repository (`ComfyUI-post-processing-nodes` uses `master`, not `main`).

| Repository | Build revision/install ID | Actual graph classes |
| --- | --- | --- |
| [cubiq/ComfyUI_essentials](https://github.com/cubiq/ComfyUI_essentials) | `ESSENTIALS_COMMIT=9d9f4bedfc9f0321c19faf71855e228c93bd0dc9` | `ImageResize+`, `GetImageSize+`, `ImageTile+`, `ImageUntile+`, `ImageListToBatch+`, `ImageFromBatch+`, `SimpleMath+`, `MaskBlur+` |
| [pythongosssss/ComfyUI-Custom-Scripts](https://github.com/pythongosssss/ComfyUI-Custom-Scripts) | Registry `comfyui-custom-scripts`, `CUSTOM_SCRIPTS_VERSION=1.2.5` | `StringFunction\|pysssss` |
| [ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack) | Registry `comfyui-impact-pack`, `IMPACT_PACK_VERSION=8.28.3` | `ImpactImageBatchToImageList`, `ToDetailerPipe`, `ToBasicPipe`, `FromBasicPipe`, `SAMLoader`, `FaceDetailerPipe` |
| [ltdrdata/ComfyUI-Impact-Subpack](https://github.com/ltdrdata/ComfyUI-Impact-Subpack) | Registry `comfyui-impact-subpack`, `IMPACT_SUBPACK_VERSION=1.3.5` | `UltralyticsDetectorProvider`; pair with Impact Pack |
| [yolain/ComfyUI-Easy-Use](https://github.com/yolain/ComfyUI-Easy-Use) | Registry `comfyui-easy-use`, `EASY_USE_VERSION=1.3.6` | `easy imageToBase64`, `easy int`, `easy imageListToImageBatch` |
| [1038lab/ComfyUI-QwenVL](https://github.com/1038lab/ComfyUI-QwenVL) | `QWENVL_COMMIT=1b67b443918801f571714bab636edc1845b7002a` | `AILab_QwenVL_GGUF` |
| [Acly/comfyui-tooling-nodes](https://github.com/Acly/comfyui-tooling-nodes) | `TOOLING_COMMIT=b3ae4aa2d98f6ac4284ddbe261e3559c94bd652b` | `ETN_LoadImageBase64` |
| [EllangoK/ComfyUI-post-processing-nodes](https://github.com/EllangoK/ComfyUI-post-processing-nodes) | `POST_COMMIT=c49a05254795403648f2c1774b6f5ea39f96e7d5` | `Blend` (not core `ImageBlend`) |
| [nunchaku-ai/ComfyUI-nunchaku](https://github.com/nunchaku-ai/ComfyUI-nunchaku) | `NUNCHAKU_COMFYUI_TAG=v1.2.1` | `NunchakuFluxDiTLoader` |
| [lquesada/ComfyUI-Inpaint-CropAndStitch](https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch) | `CROP_STITCH_COMMIT=8584b08d851762965df898b421a39075fc5357ae` | `InpaintCropImproved`, `InpaintStitchImproved` |
| [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `KJNODES_COMMIT=d3cfe21625e5170126ce06fbfcfe1d88108688c3` | `ImagePass`, `ImageResizeKJv2` |

The remaining 28 distinct classes are ComfyUI core/extras nodes, including `GetImageSize` without `+`. No additional third-party `GetImageSize` package is needed when ComfyUI supplies it.

Not referenced by v1.19, but **required by the AZ-AI graph**:

- [rgthree/rgthree-comfy](https://github.com/rgthree/rgthree-comfy), registry `rgthree-comfy`, `RGTHREE_VERSION=1.0.2608210019`: `Context (rgthree)`, `Context Switch (rgthree)`.
- [WASasquatch/was-node-suite-comfyui](https://github.com/WASasquatch/was-node-suite-comfyui), `WAS_COMMIT=ea935d1044ae5a26efa54ebeb18fe9020af49a45`: `Mask Crop Region`.

Installed but referenced by neither graph:

- [Local GPU selector](custom_nodes/momi_gpu_model_selector/__init__.py), copied from this repository, no independent public node repository/additional requirements file; depends on Torch and ComfyUI model management.

Manual Git installation example (Linux/container shell):

```bash
git clone https://github.com/cubiq/ComfyUI_essentials /comfyui/custom_nodes/ComfyUI_essentials
git -C /comfyui/custom_nodes/ComfyUI_essentials checkout 9d9f4bedfc9f0321c19faf71855e228c93bd0dc9
/opt/venv/bin/python -m pip install -r /comfyui/custom_nodes/ComfyUI_essentials/requirements.txt
```

Repeat using each table repository/revision; install a requirements file only if it exists. Registry installation in Docker uses the bundled [comfy-node-install wrapper](scripts/comfy-node-install.sh):

```bash
comfy-node-install rgthree-comfy@1.0.2608210019 comfyui-custom-scripts@1.2.5 comfyui-impact-pack@8.28.3 comfyui-impact-subpack@1.3.5 comfyui-easy-use@1.3.6
```

This calls `comfy node install --mode=remote` and then checks each node's folder and version. The installer alone is not enough: for a version that does not exist it prints the available versions and exits with 0.

Nunchaku needs both its node repository and backend wheel. Docker also saves `https://nunchaku.tech/cdn/nunchaku_versions.json` at `/comfyui/custom_nodes/ComfyUI-nunchaku/nunchaku_versions.json`. ComfyUI-nunchaku v1.2.1 imports `apply_rotary_emb` from ComfyUI's Qwen-Image model; on a ComfyUI release that does not export it (v0.24.0, for example) the whole node package fails to import. The build detects that case and patches `models/qwenimage.py` to use `comfy.ldm.flux.math.apply_rope1`; on releases that export the function, such as v0.38.0, it leaves the node untouched. Qwen GGUF needs both its node and the vision-capable llama-cpp wheel; Transformers alone does not provide that backend.

## 5. Python and OS dependencies

The [Dockerfile](Dockerfile) defines the installation order:

- OS: `python3.12`, `python3.12-venv`, `python3-pip`, `git`, `wget`, `libgl1`, `libglib2.0-0`, `libsm6`, `libxext6`, `libxrender1`, `ffmpeg`; enhancement core adds `curl`, `ca-certificates`.
- Bootstrap: `uv`, `comfy-cli`, `pip`, `setuptools`, `wheel`; configured CUDA Torch/torchvision/torchaudio. The requested PyTorch build is installed first and comfy-cli runs with `--skip-torch-or-directml`, so there is one PyTorch/CUDA stack in the image.
- One Python environment. The base stage sets `VIRTUAL_ENV=/opt/venv`. comfy-cli only uses an existing environment when that variable is set; with `PATH` alone it created a second venv at `/comfyui/.venv` and installed PyTorch, ComfyUI's requirements and all registry-node requirements there, while the entrypoint ran `/opt/venv/bin/python`. The build now fails if `/comfyui/.venv` appears.
- ComfyUI's `/comfyui/requirements.txt`, installed into `/opt/venv` by comfy-cli and re-synced in the shared final stage and enhancement overlay.
- Worker: `runpod`, `requests` and `websocket-client` at the versions in the repository's `requirements.txt`, which the Docker build installs.
- Every installed custom node's requirements when present; enhancement overlay adds `piexif`, `ultralytics`, `segment-anything`, `dill`.
- [Nunchaku node requirements at v1.2.1](https://github.com/nunchaku-ai/ComfyUI-nunchaku/blob/v1.2.1/requirements.txt): `diffusers>=0.35`, `transformers>=4.54`, `sentencepiece`, `protobuf`, `huggingface_hub>=0.34`, `tomli`, `peft>=0.17`, `accelerate>=1.10`, `insightface`, `opencv-python`, `facexlib`, `onnxruntime`, `timm`, plus the compiled Nunchaku wheel.
- [QwenVL current requirements](https://github.com/1038lab/ComfyUI-QwenVL/blob/main/requirements.txt): `transformers`, `torch`, `huggingface-hub`, `hf_xet`, `psutil`, `numpy`, `Pillow`, `opencv-python`, `bitsandbytes`, `accelerate`; vision GGUF separately uses llama-cpp-python. The manifest notes Transformers >=4.57 for the Qwen3-VL HF backend; this graph uses GGUF.

The package versions of `v07` are in [constraints/general-enhancement-v07.txt](constraints/general-enhancement-v07.txt), which the `enhance` targets pass as `PIP_CONSTRAINTS_FILE`: it is `pip-freeze-v07.txt` without its six direct references. The base stage copies it to `/opt/pip-constraints.txt` after PyTorch is installed and sets `PIP_CONSTRAINT` and `UV_CONSTRAINT`, so ComfyUI's requirements and every custom node's requirements resolve to the recorded versions; a package that is not in the file is not restricted. Binary availability can still change; the runtime base lacks a full compiler/CUDA development toolchain. If an upstream package requires a source build, select a compatible wheel or explicitly add its documented build dependencies. Do not assume arbitrary pip upgrades remain Nunchaku-compatible.

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
| `HUGGINGFACE_ACCESS_TOKEN` | Optional environment variable, passed to the build as the secret `hf_token`. Only selects the gated FLUX.1-schnell source for the Flux autoencoder; without it the identical file comes from an ungated repository. |
| `ENHANCE_EXTRA_MODELS` | `false`. `true` also bundles the three assets no enhancement graph selects (about 19 GB). |
| `CIVITAI_API_TOKEN` | Environment variable, passed as the secret `civitai_token`. Only used with `ENHANCE_EXTRA_MODELS=true`: Kreamania returns HTTP 401 without it. |
| `KREAMANIA_FP8_SHA256` | Only used with `ENHANCE_EXTRA_MODELS=true`. Optional trusted hash; empty skips Kreamania's integrity check. Repository supplies no expected hash. |
| `FLUX_VAE_SHA256`, `FLUX_VAE_UNGATED_URL` | Expected hash of `ae.safetensors` and its ungated source. |
| `COMFYUI_VERSION` | Dockerfile/Bake default `0.38.0`, the validated release. |
| `PIP_CONSTRAINTS_FILE` | `constraints/general-enhancement-v07.txt` for this target (set in the Bake `enhance` targets): the package versions of the `v07` image. Every pip/uv installation after PyTorch may only choose those versions. The Dockerfile default, `constraints/none.txt`, is empty. |
| `UV_VERSION`, `COMFY_CLI_VERSION` | `0.12.23`, `1.22.0`: the versions in `v07`. |
| `RGTHREE_VERSION`, `CUSTOM_SCRIPTS_VERSION`, `IMPACT_PACK_VERSION`, `IMPACT_SUBPACK_VERSION`, `EASY_USE_VERSION` | Registry node versions; defaults in the node table. |
| `PYTORCH_VERSION`, `TORCHVISION_VERSION`, `TORCHAUDIO_VERSION` | `2.10.0`, `0.25.0`, `2.10.0` for this target (set in the Bake `enhance` targets). Leaving them empty installs the newest cu128 PyTorch, which no longer matches the Nunchaku wheel and fails the final check. |
| `MODEL_TYPE` | Must be `enhance` for a fresh enhancement core. |
| `ENHANCE_CORE_IMAGE` | Default `final-enhance-core` builds the in-file core; a compatible image reference reuses that core. |
| `DOCKERHUB_REPO`, `RELEASE_VERSION` | Bake namespace/tag; defaults `momensirribrick`, `latest`. |
| `ESSENTIALS_COMMIT`, `WAS_COMMIT` | Pinned defaults in the node table; Docker build arguments. |
| `QWENVL_COMMIT`, `TOOLING_COMMIT`, `POST_COMMIT`, `CROP_STITCH_COMMIT`, `KJNODES_COMMIT` | Pinned to the commits in the node table; override with Docker arguments or Bake `--set`. |
| `NUNCHAKU_COMFYUI_TAG`, `NUNCHAKU_WHEEL_URL` | Node/backend selections described above. |
| `LLAMA_CPP_WHEEL_URL`, `LLAMA_CPP_WHEEL_SHA256` | Vision wheel and its checksum, described above. |
| `FLUXMANIA_SVDQ_INT4_URL` | Overlay INT4 download source from the model table. |

Compose loads `.env` at runtime; Docker does not automatically populate build arguments from it. Load its values into the current shell:

```bash
set -a
source .env
set +a
export RELEASE_VERSION=v07
```

PowerShell:

```powershell
Get-Content .env | ForEach-Object {
    if ($_ -notmatch '^\s*(#|$)') {
        $name, $value = $_ -split '=', 2
        [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), 'Process')
    }
}
$env:RELEASE_VERSION = 'v07'
```

The default build needs no token. Tokens are BuildKit secrets, not build arguments: Bake passes `HUGGINGFACE_ACCESS_TOKEN` and `CIVITAI_API_TOKEN` as the secrets `hf_token` and `civitai_token` when the variables are set, so they are not stored in the build cache, the image history or the output of `bake --print`. With plain `docker buildx build`, add `--secret id=hf_token,env=HUGGINGFACE_ACCESS_TOKEN`; `--build-arg HUGGINGFACE_ACCESS_TOKEN` no longer has any effect. The steps that read a token do not echo their commands, and the tokenized Kreamania request is quiet. Runtime inference needs no download credentials when all files are present.

## 7. Build

From the repository root, Bash/WSL:

```bash
docker buildx build --platform linux/amd64 --load \
  --target final-enhance -t momensirribrick/general-enhancement:v07 \
  --build-arg BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04 \
  --build-arg COMFYUI_VERSION=0.38.0 \
  --build-arg CUDA_VERSION_FOR_COMFY= \
  --build-arg ENABLE_PYTORCH_UPGRADE=true \
  --build-arg PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128 \
  --build-arg PYTORCH_VERSION=2.10.0 \
  --build-arg TORCHVISION_VERSION=0.25.0 \
  --build-arg TORCHAUDIO_VERSION=2.10.0 \
  --build-arg PIP_CONSTRAINTS_FILE=constraints/general-enhancement-v07.txt \
  --build-arg MODEL_TYPE=enhance .
```

Without the `PIP_CONSTRAINTS_FILE` line this is the command the `v07` image was built with; that line makes a rebuild choose the same package versions. Add `--secret id=hf_token,env=HUGGINGFACE_ACCESS_TOKEN` to take the autoencoder from the gated repository, or `--build-arg ENHANCE_EXTRA_MODELS=true --build-arg KREAMANIA_FP8_SHA256 --secret id=civitai_token,env=CIVITAI_API_TOKEN` for the optional assets.

For PowerShell replace `\` continuations with backticks or use this one-line Bake equivalent (the `enhance` targets already pin ComfyUI, PyTorch and the constraints file):

```powershell
$env:RELEASE_VERSION = 'v08'; docker buildx bake -f docker-bake.hcl enhance --load
```

Bake's default group is `enhance` alone; every other image has to be named. Stage chain: `base → final → final-enhance-core → final-enhance`, with models copied in from `downloader`. The downloader stage is built from the CUDA base image, not from `base`, so a ComfyUI or PyTorch change reuses the cached model downloads. The models are copied as one layer per folder of `/comfyui/models` (`COPY --link`), so a changed or added model replaces only its own folder's layer when the image is pushed or pulled.

The last overlay step is a gate. The build fails if PyTorch or its CUDA version no longer matches the ABI in the Nunchaku wheel's version tag, if the compiled Nunchaku extension does not import, if a workspace venv exists, or if any file in `models.sha256` is missing or has a different hash.

### Required build context/image files

Keep these repository paths: `Dockerfile`, `requirements.txt`, `constraints/`, `scripts/build/`, `scripts/comfy-node-install.sh`, `scripts/comfy-manager-set-mode.sh`, `src/extra_model_paths.yaml`, `src/start.sh`, `src/network_volume.py`, `handler.py`, `test_input.json`, `workflows/general-enhancement/models.sha256`, and `custom_nodes/momi_gpu_model_selector/`. Linux scripts need LF endings; CRLF in `/start.sh` can prevent startup. `.dockerignore` controls local asset inclusion.

The final overlay installs dependency fixes, INT4 Fluxmania, the local GPU selector, CropAndStitch, and KJNodes. Worker files are copied from the small `runtime-files` stage last for fast handler rebuilds. The workflow and test helper are host-side artifacts, **not baked into the image**; submit the graph with each request. The baked `test_input.json` is a generic example, not an enhancement test.

### Reuse a heavy core

```bash
export RELEASE_VERSION=v07 COMFYUI_VERSION=0.38.0
docker buildx bake -f docker-bake.hcl enhance-core --load
docker buildx bake -f docker-bake.hcl enhance --set enhance.args.ENHANCE_CORE_IMAGE=momensirribrick/general-enhancement:core-v07 --load
```

Do not build an overlay on top of a previous full image (`ENHANCE_CORE_IMAGE=…:v06`, for instance): every overlay layer, including the 6.8 GB INT4 model, is then stored twice. The published `v06` was built that way.

To publish, `docker login`, set `DOCKERHUB_REPO` to a namespace you control, and use `--push` instead of `--load`. Referencing a pushed core on another machine skips its heavy rebuild. Core models, ComfyUI, nodes, Torch and llama versions remain those in that image; new core arguments passed only to the overlay do not update them. Use a known digest when reproducing a release.

## 8. Run locally or on RunPod

### Local Docker

Bash/WSL:

```bash
docker run -d --name general-enhancement --gpus all \
  -e SERVE_API_LOCALLY=true -e COMFY_LOG_LEVEL=INFO \
  -p 127.0.0.1:8000:8000 -p 127.0.0.1:8188:8188 \
  momensirribrick/general-enhancement:v07
docker logs -f general-enhancement
```

PowerShell:

```powershell
docker run -d --name general-enhancement --gpus all -e SERVE_API_LOCALLY=true -e COMFY_LOG_LEVEL=INFO -p 127.0.0.1:8000:8000 -p 127.0.0.1:8188:8188 momensirribrick/general-enhancement:v07
```

For faithful conditioning add the embeddings mount above. Optionally mount a host output directory at `/comfyui/output` to persist results. Uploads are placed in `/comfyui/input`. An empty mount over `/comfyui/models` hides bundled weights.

Port 8000 is the worker API; 8188 is ComfyUI. `SERVE_API_LOCALLY=true` starts ComfyUI with `--listen` and the RunPod SDK with `--rp_serve_api --rp_api_host=0.0.0.0`. Handler access to ComfyUI is hardcoded to `127.0.0.1:8188`. With the installed RunPod SDK (1.12.0) the local API routes are `/run`, `/runsync`, `/status/{job_id}` and `/stream/{job_id}`; there is no `/health`. In this local mode the SDK logs `Failed to return job results. | JOB_DONE_URL` for every progress update, because there is no RunPod job API to report to. It is harmless there and does not occur on RunPod.

### Compose

The base Compose currently selects a Flux2-Klein image. Use the enhancement override, whose filename says v04 but whose image is v07:

```bash
docker compose -f docker-compose.yml -f docker-compose.enhance.override.yml config
docker compose -f docker-compose.yml -f docker-compose.enhance.override.yml up -d
```

Inspect resolved config locally: confirm enhancement image, GPU reservation, and host ports. Port lists can merge: the override adds 8001/8189 alongside base 8000/8188. Set helper URLs to the published ports. Compose requires `.env`, uses `pull_policy: never` (build/pull first), and mounts `./data/comfyui/output` and `./data/runpod-volume`. Avoid conflicts with another container using those ports.

### RunPod Serverless

Push the final image, create a GPU Serverless endpoint using its tag/digest, and set runtime variables there. Leave `SERVE_API_LOCALLY` unset/false. Submit the same `input.workflow` and `input.images` to the endpoint's `/run` or `/runsync` with RunPod authorization. For long jobs use asynchronous `/run` and poll status; configure sufficient platform execution timeouts.

### Runtime configuration

| Variable | Default / purpose |
| --- | --- |
| `SERVE_API_LOCALLY` | Unset/false; `true` for local API. |
| `COMFY_LOG_LEVEL` | `DEBUG`; `INFO` is less verbose. |
| `RUNPOD_LOG_LEVEL` | RunPod SDK log level. The handler sets `INFO` when it is unset or blank. At `DEBUG`, the SDK's own default, the SDK logs the handler's whole output, which includes the presigned output URLs (or the base64 image). An image built before the handler set this default, `v07` included, logs at `DEBUG` unless the endpoint sets `INFO`. The handler's own log lines do not contain the signed query string of an input image or of a result, and a failed node's message has the query string of every URL cut. Two things are not covered: ComfyUI's own output is not filtered, and a graph that ComfyUI refuses is reported as ComfyUI words it, a link inside the graph included. |
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

[src/extra_model_paths.yaml](src/extra_model_paths.yaml) maps `/runpod-volume/models/` categories `checkpoints`, `clip`, `clip_vision`, `configs`, `controlnet`, `embeddings`, `loras`, `upscale_models`, `vae`, and `unet`. It does **not explicitly map** enhancement categories `text_encoders`, `diffusion_models`, `llm/GGUF`, `sams`, or `ultralytics`. Bundled local files work normally; migrating everything to a volume requires explicit extra-path/custom-node setup. Qwen path integration depends on node version, and Linux `llm` and `LLM` differ. The files are stored under lowercase `llm/GGUF`, but the pinned ComfyUI-QwenVL (v2.3.2) resolves `LLM/GGUF` and only falls back to an all-lowercase `llm/gguf`. With just the lowercase directory it finds the model through a recursive search but not the projector, and downloads 836 MB from Hugging Face on a worker's first job. The image therefore has `/comfyui/models/LLM` as a link to `llm`, and the build fails if the model or projector is not at the path the node's own catalog resolves.

## 9. Validate and test

Wait for startup and inspect logs for failed custom-node imports. Then:

```bash
curl http://127.0.0.1:8188/object_info
curl http://127.0.0.1:8000/openapi.json
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

A signed URL is a credential. When a download fails, the worker log and the job's `output.details` name only the failure kind (`HTTP 403`, `ConnectionError`, a timeout), never the URL or its query string.

For Compose override ports add `--comfy-url http://127.0.0.1:8189 --worker-url http://127.0.0.1:8001`. The execution HTTP timeout defaults to 3600 seconds (`--timeout` overrides it); this cannot extend SDK/platform execution limits. Preflight does not load weights or validate embeddings, projectors, all linked types, or GPU kernels. Resolve node-version/input mismatches deliberately before execution.

### Execute manually and inspect output

After generating the payload:

```bash
curl -X POST http://127.0.0.1:8000/runsync \
  -H 'Content-Type: application/json' \
  --data-binary @general-enhancement-input.json
```

With `--run`, the helper saves `general-enhancement-result.json`. The handler returns `output.images`, a list with one object per saved image: `filename`, `type` (`s3_url` when the `BUCKET_*` variables are set, otherwise `base64`) and `data` (the URL or the base64 string). This is the shape in the main README, in the published `v06` image, and the one the AZ-AI backend validates: exactly one image with `type: "s3_url"`. A failed job has `output.error` and optional `output.details` instead. Inspect the job status as well; HTTP success alone is insufficient. PNGs also appear in `/comfyui/output`.

Decode base64 outputs with host Python:

```python
import base64, json
from pathlib import Path
result = json.loads(Path("general-enhancement-result.json").read_text(encoding="utf-8"))
for image in result["output"]["images"]:
    if image["type"] == "s3_url":
        print(image["data"])
    else:
        Path("enhanced-" + image["filename"]).write_bytes(base64.b64decode(image["data"]))
```

Use a representative photograph: tiny samples may bypass person/face detections. The graph resizes to a 1280–5120 range in its detailer path, uses roughly 900-pixel tile sizing, 25-step Flux passes, 30-step SD refinement, and retains Qwen in memory. Resolution, tile count and detections affect time/VRAM. Test one request at a time. Reducing dimensions/steps for a smoke test changes the workflow and does not benchmark the original.

## 10. Limitations and troubleshooting

| Symptom / gap | Explanation / action |
| --- | --- |
| Generic `test_input.json` cannot load `flux1-dev-fp8.safetensors` | This sample's checkpoint is not bundled in enhancement. Use the dedicated v1.19 helper. |
| Missing EasyNegative/epiCNegative | Supply originals or explicitly remove their references using the helper adaptation; epiCNegative's original source/version remains unknown, and as written it is not loaded anyway (see section 3). |
| Unsupported FP4 GPU | Graph bypasses the bundled selector. Adapt node `40` (AZ-AI graph: node `209`) to INT4 on compatible hardware. |
| Nunchaku import/kernel/undefined-symbol failure | Check final Torch 2.10 / cu128 / Python 3.12 and wheel ABI after node installs. |
| Qwen vision handler/projector failure, or `[QwenVL] Downloading mmproj…` in the log | Check GGUF plus F16 projector, case-sensitive paths (`/comfyui/models/LLM` must resolve), and configured vision wheel. Build-time source checks are not CUDA inference tests. |
| Unknown `GetImageSize` / changed required inputs | ComfyUI/node branches move. Use preflight and pin a compatible set; inspect import errors. |
| Models absent on network volume | Check extra-path coverage/case and mounts hiding local bundled files. |
| HF/Civitai download failure, or `sha256sum` reports `FAILED` | Check access, availability and disk. A changed upstream file fails the checksum gate: review it, then update `models.sha256`. Kreamania is only downloaded with `ENHANCE_EXTRA_MODELS=true` and needs a Civitai token. |
| Input image missing | Replace node `81`'s local path with the uploaded name; helper does this. |
| Job fails with `Failed to upload one or more input images` | The URL in `input.images` could not be downloaded. `output.details` gives the kind (`HTTP 403`, timeout, not an image, over 50 MiB); the URL itself is deliberately not logged. |
| Output is an enlarged top-left crop | AZ-AI graph with the Advanced Detailer on an input under 2048 px: a defect in the backend's workflow template, not in the image. |
| `ComfyUI HTTP unreachable during websocket reconnect` | ComfyUI died mid-job. Seen once here on a 12 GB GPU with VRAM nearly full: llama-cpp logged `ggml-cuda.cu:97: CUDA error`, then `Fatal Python error: Aborted`. The job fails and the worker asks to be refreshed. Probably memory exhaustion; check the worker log for the same two lines. |
| `You need pytorch with cu130 or higher` at startup | ComfyUI 0.38.0 would use optimized CUDA operations with cu130. The Nunchaku and llama-cpp wheels here are cu128; jobs run on the standard PyTorch path. |
| OOM/long runs | Several high-resolution passes, retained Qwen and detections add work. Inspect offloading/logs; deliberately tune resolution/steps/model retention if needed. |
| UI import unavailable | Supplied graph is API format; submit via API or obtain a separate UI-format export. |

No private service dependency is identified in the graph. Internal project components are the worker/entrypoint, path configuration and bundled local GPU selector. Some nodes are disconnected from final output (for example `88`); preflight conservatively checks the entire graph. Storage and Comfy.org integrations are optional.

The project now records the validated ComfyUI version, pinned Git nodes, model hashes and the resulting package list. Registry nodes and the unpinned Python packages (`comfy-cli`, `runpod`, node requirements) are still resolved at build time, so a later build can differ from `pip-freeze-v07.txt`. Original embedding hashes, a GPU matrix beyond the RTX 3060 and a measured resource minimum are still missing.

## Audit sources

- Project: [Dockerfile](Dockerfile), [Bake configuration](docker-bake.hcl), [workflow](workflows/general-enhancement/workflow_api_flux_dev_1.19.json), [handler](handler.py), [entrypoint](src/start.sh).
- Registration checks: [Essentials pinned image nodes](https://github.com/cubiq/ComfyUI_essentials/blob/9d9f4bedfc9f0321c19faf71855e228c93bd0dc9/image.py), [KJNodes](https://github.com/kijai/ComfyUI-KJNodes), [CropAndStitch](https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch), [ComfyUI image extras](https://github.com/Comfy-Org/ComfyUI/blob/master/comfy_extras/nodes_images.py), [Nunchaku v1.2.1 Flux loader](https://github.com/nunchaku-ai/ComfyUI-nunchaku/blob/v1.2.1/nodes/models/flux.py), and repositories linked above.
- [Vision llama-cpp release](https://github.com/JamePeng/llama-cpp-python/releases/tag/v0.3.30-cu128-Basic-linux-20260302), manifests and model download links in the preceding sections.
