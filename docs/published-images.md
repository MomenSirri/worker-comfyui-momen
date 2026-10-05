# Published images and what this repository reproduces

Checked on 2026-10-05. Several published images were built from working copies that were never committed. This page records what each published tag contains, how that was found out, and which of them the current Dockerfile reproduces.

## How a published image was read

Docker Hub keeps the build history of every image: each `RUN`, `COPY` and `ARG` with its text and the size of its layer. That history, and single small layers, can be read from the registry without pulling a 30 to 50 GB image:

- the image configuration (`/v2/<repository>/blobs/<config digest>`) lists every build step;
- the layer of one step can be downloaded on its own, for example the 100 MB layer of the registry node installation, to read each node's `pyproject.toml`;
- the first megabytes of the ComfyUI layer contain `comfyui/.git/HEAD`, which names the ComfyUI commit.

The repositories are public, so an anonymous pull token is enough.

## Two output contracts share one handler file

The handler has returned two different shapes over time. An application only works with the images built with its shape.

| Contract | Handler returns | Used by |
| --- | --- | --- |
| `output.images` | `{"images": [{"data", "filename", "type"}]}` | AZ-AI. Its backend rejects every other shape (`runpod-response.validator.ts`). |
| `output.message` | `{"status": "success", "message": [...]}` | The handler on `main` (`56d8cec`). |

The current handler returns `output.images`.

## SeedVR upscaler (`momensirribrick/seedvr`)

| Tag | Published | Handler contract | Built from |
| --- | --- | --- | --- |
| `v01`, `v02` | 2026-03 | not checked | not checked |
| `v03` | 2026-03-19 | `output.message` | not checked |
| `v04` | 2026-06-05 | `output.images` | An uncommitted working copy of `main` (`56d8cec`) on the owner's workstation |
| `v05` | 2026-08-31 | `output.message` | A later Dockerfile revision that is not in this repository |
| `v06` | 2026-09-03 | `output.message` | The same later revision, plus a FLUX.2 Klein restore set (below) |
| `seedance-0.38.0` | 2026-09-30 | not checked | not checked |

Of `v03` to `v06`, only `v04` has the contract AZ-AI needs, so the `seedvr` Bake target reproduces **`v04`'s content with the current handler**:

| Part | In `v04` | In the `seedvr` target |
| --- | --- | --- |
| ComfyUI | v0.24.1 (`ba9ffa0a`), installed as `latest` on the build day | `SEEDVR_COMFYUI_VERSION=0.24.1` |
| PyTorch | newest cu128 build of that day, with the Nunchaku wheel for PyTorch 2.10 | 2.10.0 / cu128, pinned |
| Registry nodes | `seedvr2_videoupscaler` 2.5.22, `rgthree-comfy` 1.0.2605082257, `comfyui-custom-scripts` 1.2.5, `ComfyUI-DyPE` 2.3.0, `comfyui_ultimatesdupscale` 1.7.2 | the same versions, pinned |
| Git nodes | ComfyUI-nunchaku `v1.2.1`, ComfyUI_essentials `9d9f4be`, ComfyUI-KJNodes `2ad3602` (the `main` of that day), was-node-suite `ea935d1` | the same revisions, pinned |
| SeedVR2 model | `seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors`, copied from a local `models/SEEDVR2` folder, with the plain FP8 file name as a link to it | the same file from `AInVFX/SeedVR2_comfyUI` on Hugging Face (the local copy has the same SHA256), with the same link |
| Other models | Flux text encoders, Flux autoencoder, `ema_vae_fp16`, `4xNomos8kDAT`, Fluxmania SVDQ FP4 | the same files, each checked against `workflows/seedvr-upscale/models.sha256` |
| Build checks | none | custom-node import check, PyTorch/Nunchaku ABI check, model checksums |

Two things the rebuild showed about that combination:

- **The SeedVR2 node cannot be imported without a GPU.** It builds its device lists from the GPUs it finds and raises `list index out of range` when there is none, so ComfyUI reports `IMPORT FAILED` for it in any CPU-only start. The build's import check therefore skips this one node and checks three of its Python dependencies instead. Whether the node loads has to be confirmed on a GPU host.
- **The ComfyUI-nunchaku patch applies on ComfyUI v0.24.1.** `scripts/build/patch-nunchaku-qwenimage.py` found no `apply_rotary_emb` definition in that release and switched the node to the Flux helper; with it every other node imports. `v04`'s build had no such step, and whether its Nunchaku node imports was not checked.

The AZ-AI upscale graph (`backend/libs/integrations/src/runpod/workflows/Seedvr_flux_upscaler_02.json`) selects exactly the seven model files in that checksum list.

**The `seedvr` target has not been built with its models, and no job has run on it.** Checked on 2026-10-05: a complete build without the model downloads (`MODEL_TYPE=base`, with a checksum list that names one small file). The pinned registry and Git nodes installed at the versions above, the Nunchaku wheel imported, the import check passed for every node except SeedVR2, and the PyTorch/Nunchaku check passed. The seven download addresses were not fetched by a build; the SHA256 values come from the Hugging Face file listings, and three of them were compared with local copies of the files.

Before an endpoint uses a new SeedVR image: build it with the models, run it on a GPU host, and run one upscale job per engine (`SUPER_FAST` and `NORMAL`) with the AZ-AI graph.

Not reproduced: `v05` and `v06`. They return `output.message`. `v06` also adds, on top of the SeedVR image, `flux-2-klein-9b-fp8`, `qwen_3_8b_fp8mixed`, the VAE `full_encoder_small_decoder`, the LoRA `arch_restore_flux2_klein9b_lora_v3_000002500`, the Qwen3-VL GGUF model with its projector, ComfyUI-QwenVL at `517aed6` and llama-cpp-python 0.3.49 (cu128). Two of those files exist only on the machine that built it.

Which tag a RunPod endpoint runs is set in the RunPod console and was not checked.

## FLUX.2 Klein (`momensirribrick/flux2-klein9b`)

`v06` (2026-06-14) was built from the same uncommitted working copy as `seedvr:v04`. The `flux2-klein-cuda12-8-1` target now matches it:

- eleven LoRA files from `./models/loras` (the eleventh, `sk2real_flux2_klein_9b_v9.9.safetensors`, was missing here);
- ComfyUI_essentials `9d9f4be` and ComfyUI-KJNodes `3e80b28` (missing here);
- ComfyUI v0.24.1, and the registry nodes `comfyui-depthanythingv2` 1.0.2, `ComfyUI-QwenVL` 2.1.1 and `comfyui-custom-scripts` 1.2.5, now pinned.

Its PyTorch version was not read and stays unpinned. The LoRA files are not in the repository; the target cannot be built without them.

## General Enhancement (`momensirribrick/general-enhancement`)

`v07` (2026-10-04) was built from commit `c4aaddc` of this repository. [README-General-Enhancement.md](../README-General-Enhancement.md) has its full record. The `enhance` target pins what that image contains: ComfyUI 0.38.0, the registry node versions, and every Python package through `constraints/general-enhancement-v07.txt`.
