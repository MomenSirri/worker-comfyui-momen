"""Keep ComfyUI-nunchaku importable on ComfyUI releases without apply_rotary_emb.

ComfyUI-nunchaku imports apply_rotary_emb from ComfyUI's Qwen-Image model. ComfyUI
releases that do not export it break the import of the whole node package,
NunchakuFluxDiTLoader included, so use the equivalent Flux helper there.
"""
from pathlib import Path

comfy_model = Path("/comfyui/comfy/ldm/qwen_image/model.py")
target = Path("/comfyui/custom_nodes/ComfyUI-nunchaku/models/qwenimage.py")
text = target.read_text()
old = """    QwenImageTransformer2DModel,
    QwenTimestepProjEmbeddings,
    apply_rotary_emb,
)
"""
new = """    QwenImageTransformer2DModel,
    QwenTimestepProjEmbeddings,
)
from comfy.ldm.flux.math import apply_rope1 as apply_rotary_emb
"""
if "def apply_rotary_emb" in comfy_model.read_text():
    print("ComfyUI exports apply_rotary_emb; ComfyUI-nunchaku left unpatched")
elif old in text:
    target.write_text(text.replace(old, new))
    print("Patched ComfyUI-nunchaku models/qwenimage.py to use apply_rope1")
else:
    raise SystemExit("ComfyUI-nunchaku models/qwenimage.py has an unexpected import block; review this patch")
