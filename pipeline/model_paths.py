"""Resolve local model assets without changing development fallbacks."""

import os


BIREFNET_REPO = "ZhengPeng7/BiRefNet-matting"
BIREFNET_FP16_DIRNAME = "birefnet-fp16"


def weights_dir(project_root=None):
    """Return the configured weight root used by source and bundled builds."""
    if project_root is None:
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.environ.get(
        "REALPET_WEIGHTS_DIR", os.path.join(project_root, "weights"))


def birefnet_checkpoint(project_root=None):
    """Prefer the bundled FP16 checkpoint, retaining the Hub development path."""
    explicit = os.environ.get("REALPET_BIREFNET_CHECKPOINT")
    if explicit:
        return explicit

    local_dir = os.path.join(
        weights_dir(project_root), BIREFNET_FP16_DIRNAME)
    required = ("config.json", "model.safetensors", "birefnet.py")
    if all(os.path.isfile(os.path.join(local_dir, name)) for name in required):
        return local_dir
    return BIREFNET_REPO
