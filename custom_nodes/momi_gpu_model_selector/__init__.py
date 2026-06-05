import logging

import torch

try:
    import comfy.model_management
except Exception:  # pragma: no cover - ComfyUI provides this at runtime
    comfy = None


logger = logging.getLogger(__name__)


def _cuda_device_count():
    if not torch.cuda.is_available():
        return 0
    return torch.cuda.device_count()


def _current_comfy_cuda_index():
    if comfy is None:
        return torch.cuda.current_device()

    device = comfy.model_management.get_torch_device()
    if getattr(device, "type", None) == "cuda":
        return 0 if device.index is None else device.index

    return torch.cuda.current_device()


def _resolve_cuda_index(device_id):
    count = _cuda_device_count()
    if count == 0:
        return None

    if device_id is None or device_id < 0:
        index = _current_comfy_cuda_index()
    else:
        index = device_id

    if index < 0 or index >= count:
        raise ValueError(f"Invalid CUDA device_id {index}. This ComfyUI session sees {count} CUDA device(s).")

    return index


def _gpu_info(device_id=-1):
    index = _resolve_cuda_index(device_id)
    if index is None:
        return {
            "device_id": None,
            "name": "No CUDA GPU detected",
            "capability": None,
            "sm": "none",
            "is_blackwell_fp4": False,
        }

    major, minor = torch.cuda.get_device_capability(index)
    name = torch.cuda.get_device_name(index)
    sm = f"{major}{minor}"

    # Nunchaku's Flux model registration also uses sm_120 for the FP4/Blackwell path.
    # RTX 5090/5080-class Blackwell cards report CUDA capability 12.0, while RTX 4090 is 8.9.
    return {
        "device_id": index,
        "name": name,
        "capability": f"{major}.{minor}",
        "sm": sm,
        "is_blackwell_fp4": sm == "120",
    }


class MomiNunchakuFluxGPUModelSelector:
    @classmethod
    def INPUT_TYPES(cls):
        max_device_id = max(_cuda_device_count() - 1, 0)
        return {
            "required": {
                "device_id": (
                    "INT",
                    {
                        "default": -1,
                        "min": -1,
                        "max": max_device_id,
                        "step": 1,
                        "display": "number",
                        "tooltip": "-1 uses the current ComfyUI CUDA device. Use 0, 1, etc. to force a GPU.",
                    },
                ),
                "input_1_blackwell_model": (
                    "MODEL",
                    {
                        "lazy": True,
                        "tooltip": "Used when the current GPU is RTX 50 / Blackwell FP4 capable (sm_120), e.g. RTX 5090.",
                    },
                ),
                "input_2_fallback_model": (
                    "MODEL",
                    {
                        "lazy": True,
                        "tooltip": "Used for non-sm_120 GPUs, e.g. RTX 4090/Ada models.",
                    },
                ),
            },
        }

    RETURN_TYPES = ("MODEL", "BOOLEAN", "STRING")
    RETURN_NAMES = ("model", "is_blackwell_fp4", "gpu_info")
    FUNCTION = "select_model"
    CATEGORY = "Momi/Nunchaku"
    TITLE = "Nunchaku Flux GPU Model Selector"

    @classmethod
    def IS_CHANGED(cls, device_id, input_1_blackwell_model=None, input_2_fallback_model=None):
        info = _gpu_info(device_id)
        return f"{info['device_id']}|{info['name']}|sm_{info['sm']}|blackwell_fp4={info['is_blackwell_fp4']}"

    def check_lazy_status(self, device_id, input_1_blackwell_model=None, input_2_fallback_model=None):
        info = _gpu_info(device_id)
        if info["is_blackwell_fp4"] and input_1_blackwell_model is None:
            return ["input_1_blackwell_model"]
        if not info["is_blackwell_fp4"] and input_2_fallback_model is None:
            return ["input_2_fallback_model"]
        return []

    def select_model(self, device_id, input_1_blackwell_model=None, input_2_fallback_model=None):
        info = _gpu_info(device_id)
        selected_model = input_1_blackwell_model if info["is_blackwell_fp4"] else input_2_fallback_model
        selected_input = "Input 1 / Blackwell FP4" if info["is_blackwell_fp4"] else "Input 2 / fallback"

        gpu_info = (
            f"{info['name']} | device_id={info['device_id']} | "
            f"cuda_capability={info['capability']} | sm_{info['sm']} | selected={selected_input}"
        )
        logger.info("[Momi Nunchaku Flux GPU Model Selector] %s", gpu_info)

        return (selected_model, info["is_blackwell_fp4"], gpu_info)


NODE_CLASS_MAPPINGS = {
    "MomiNunchakuFluxGPUModelSelector": MomiNunchakuFluxGPUModelSelector,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MomiNunchakuFluxGPUModelSelector": "Nunchaku Flux GPU Model Selector",
}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
