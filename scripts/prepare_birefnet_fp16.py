#!/usr/bin/env python3
"""Create the exact FP16 BiRefNet checkpoint used by the MPS pipeline.

The official checkpoint stores floating-point tensors as FP32, while RealPet's
supported MPS path instantiates every floating tensor as FP16. Persisting those
same converted values removes the unused FP32 copy from the app bundle and
avoids conversion-time memory without changing the model seen by inference.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

import numpy as np
from safetensors import safe_open
from safetensors.numpy import load_file, save_file


REPO_CACHE_NAME = "models--ZhengPeng7--BiRefNet-matting"
OUTPUT_DIRNAME = "birefnet-fp16"
RUNTIME_FILES = (
    "BiRefNet_config.py",
    "birefnet.py",
    "config.json",
    "handler.py",
    "requirements.txt",
)
MANIFEST_NAME = "realpet-fp16-manifest.json"
MANIFEST_FORMAT = 2


def default_source_cache():
    return Path(os.environ.get(
        "REALPET_HF_CACHE_DIR",
        Path.home() / "Library" / "Application Support" / "RealPet" / "huggingface"))


def find_snapshot(source_cache):
    """Locate the active BiRefNet snapshot in the external HF cache."""
    repo_dir = Path(source_cache) / REPO_CACHE_NAME
    snapshots_dir = repo_dir / "snapshots"
    ref_path = repo_dir / "refs" / "main"
    candidates = []
    if ref_path.is_file():
        revision = ref_path.read_text(encoding="utf-8").strip()
        if revision:
            candidates.append(snapshots_dir / revision)
    if snapshots_dir.is_dir():
        candidates.extend(sorted(snapshots_dir.iterdir(), reverse=True))
    for candidate in candidates:
        if (candidate / "model.safetensors").is_file():
            return candidate
    raise FileNotFoundError(
        f"BiRefNet snapshot not found under {snapshots_dir}")


def _source_fingerprint(model_path):
    stat = model_path.stat()
    return {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def is_current(source_dir, output_dir):
    """Return whether an existing derived checkpoint matches its source."""
    manifest_path = Path(output_dir) / MANIFEST_NAME
    model_path = Path(output_dir) / "model.safetensors"
    if not (manifest_path.is_file() and model_path.is_file()):
        return False
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return (manifest.get("format") == MANIFEST_FORMAT
            and manifest.get("source") == _source_fingerprint(
                Path(source_dir) / "model.safetensors"))


def convert_snapshot(source_dir, output_dir, force=False):
    """Convert floating tensors to FP16 and copy local-model runtime files."""
    source_dir = Path(source_dir)
    output_dir = Path(output_dir)
    source_model = source_dir / "model.safetensors"
    if not source_model.is_file():
        raise FileNotFoundError(source_model)
    for filename in RUNTIME_FILES:
        if not (source_dir / filename).is_file():
            raise FileNotFoundError(source_dir / filename)

    if not force and is_current(source_dir, output_dir):
        print(f"BiRefNet FP16 already current: {output_dir}")
        return output_dir

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
            prefix="birefnet-fp16-", dir=output_dir.parent) as tmp_name:
        tmp_dir = Path(tmp_name)
        for filename in RUNTIME_FILES:
            shutil.copy2(source_dir / filename, tmp_dir / filename)

        with safe_open(source_model, framework="np") as source:
            metadata = source.metadata()
        tensors = load_file(source_model)
        converted = {
            name: np.array(
                value,
                dtype=(np.float16 if np.issubdtype(value.dtype, np.floating)
                       else value.dtype),
                copy=True,
                order="C")
            for name, value in tensors.items()
        }
        output_model = tmp_dir / "model.safetensors"
        save_file(converted, output_model, metadata=metadata)

        manifest = {
            "format": MANIFEST_FORMAT,
            "source": _source_fingerprint(source_model),
            "floating_dtype": "float16",
            "tensor_count": len(converted),
            "model_size": output_model.stat().st_size,
        }
        (tmp_dir / MANIFEST_NAME).write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")

        if output_dir.exists():
            shutil.rmtree(output_dir)
        os.replace(tmp_dir, output_dir)

    print(f"Created BiRefNet FP16: {output_dir} "
          f"({(output_dir / 'model.safetensors').stat().st_size:,} bytes)")
    return output_dir


def main():
    parser = argparse.ArgumentParser(
        description="Prepare RealPet's MPS-equivalent FP16 BiRefNet checkpoint")
    parser.add_argument("--weights-dir", required=True,
                        help="Release weight root receiving birefnet-fp16")
    parser.add_argument("--source-cache", default=str(default_source_cache()),
                        help="External Hugging Face cache containing BiRefNet")
    parser.add_argument("--output", default=None,
                        help="Output model directory (default: <weights>/birefnet-fp16)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    source = find_snapshot(args.source_cache)
    output = (Path(args.output) if args.output else
              Path(args.weights_dir) / OUTPUT_DIRNAME)
    convert_snapshot(source, output, force=args.force)


if __name__ == "__main__":
    main()
