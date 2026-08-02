#!/usr/bin/env python3
"""Fetch and verify every immutable model artifact used in a release bundle."""

import argparse
import hashlib
import os
import urllib.request
from pathlib import Path


PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.environ.get(
    "REALPET_WEIGHTS_DIR", os.path.join(PROJECT_ROOT, "weights"))

BIREFNET_REPO = "ZhengPeng7/BiRefNet-matting"
BIREFNET_REVISION = "57f9f68b43ba337c75762b14cf3075d659007268"
BIREFNET_SOURCE_SHA256 = "a9875de5b1e6c8eb5fdaa8c727a82927ce442cdc87ba3abee6a77e6fa46c25bb"
RCNN_URL = ("https://download.pytorch.org/models/"
            "fasterrcnn_resnet50_fpn_v2_coco-dd69338a.pth")
RCNN_SHA256 = "dd69338a24b8d7381807e247652bdc356325bcbaf1cd3e092e00e0a1a58706bf"


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _birefnet_source_path(out_dir: str | Path) -> Path:
    return (Path(out_dir) / "hf" / "models--ZhengPeng7--BiRefNet-matting"
            / "snapshots" / BIREFNET_REVISION / "model.safetensors")


def download_birefnet(out_dir: str, force: bool = False) -> None:
    from huggingface_hub import snapshot_download

    source = _birefnet_source_path(out_dir)
    if not force and source.is_file() and sha256_file(source) == BIREFNET_SOURCE_SHA256:
        print("BiRefNet source checkpoint verified")
        return

    dest = os.path.join(out_dir, "hf")
    print(f"Downloading BiRefNet-matting revision {BIREFNET_REVISION} to {dest} ...")
    snapshot_download(
        repo_id=BIREFNET_REPO,
        revision=BIREFNET_REVISION,
        cache_dir=dest,
        # Runtime-only snapshot. Prefer safetensors so a future duplicate .bin
        # checkpoint cannot silently double the app size.
        allow_patterns=["*.json", "*.py", "*.safetensors", "*.txt"],
    )
    if not source.is_file() or sha256_file(source) != BIREFNET_SOURCE_SHA256:
        raise RuntimeError("BiRefNet source checkpoint does not match the pinned SHA-256")


def prepare_birefnet_fp16(out_dir: str, force: bool = False) -> None:
    """Materialize the exact half-precision checkpoint used on MPS."""
    from prepare_birefnet_fp16 import convert_snapshot, find_snapshot

    source = find_snapshot(out_dir)
    output = os.path.join(out_dir, "birefnet-fp16")
    convert_snapshot(source, output, force=force)


def download_faster_rcnn(out_dir: str, force: bool = False) -> None:
    dest_dir = Path(out_dir) / "torch" / "hub" / "checkpoints"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / os.path.basename(RCNN_URL)
    if dest.is_file() and not force:
        if sha256_file(dest) == RCNN_SHA256:
            print(f"Faster R-CNN checkpoint verified: {dest}")
            return
        print("Existing Faster R-CNN checkpoint does not match the pinned SHA-256, "
              "re-downloading...")
        dest.unlink()

    print(f"Downloading Faster R-CNN to {dest} ...")
    request = urllib.request.Request(
        RCNN_URL,
        headers={"User-Agent": "RealPet release preparation"},
    )
    temporary = dest.with_suffix(f"{dest.suffix}.download")
    if temporary.exists():
        temporary.unlink()
    try:
        with urllib.request.urlopen(request) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        if sha256_file(temporary) != RCNN_SHA256:
            raise RuntimeError("Faster R-CNN checkpoint does not match the pinned SHA-256")
        temporary.replace(dest)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"Faster R-CNN checkpoint verified: {dest}")


def verify(out_dir: str) -> bool:
    """Return whether all source and generated release assets match hashes."""
    from verify_release_assets import verify_release_assets

    return verify_release_assets(Path(out_dir))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bundle pinned model weights for the RealPet release app.")
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="Output directory (default: weights/ or REALPET_WEIGHTS_DIR).")
    parser.add_argument("--force", action="store_true",
                        help="Re-fetch the pinned source artifacts.")
    parser.add_argument("--verify-only", action="store_true",
                        help="Validate existing artifacts without downloading.")
    args = parser.parse_args()

    Path(args.out).mkdir(parents=True, exist_ok=True)
    os.environ["REALPET_WEIGHTS_DIR"] = args.out

    if args.verify_only:
        return 0 if verify(args.out) else 1

    from download_weights import download_sam2

    print("Preparing SAM2...")
    if not download_sam2(force=args.force):
        return 1
    print("Preparing BiRefNet...")
    download_birefnet(args.out, force=args.force)
    prepare_birefnet_fp16(args.out, force=args.force)
    print("Preparing Faster R-CNN...")
    download_faster_rcnn(args.out, force=args.force)
    return 0 if verify(args.out) else 1


if __name__ == "__main__":
    raise SystemExit(main())
