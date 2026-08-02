#!/usr/bin/env python3
"""Verify the immutable model artifacts accepted by a RealPet release build."""

import argparse
import hashlib
import os
import sys
from pathlib import Path


BIREFNET_REVISION = "57f9f68b43ba337c75762b14cf3075d659007268"
ASSETS = (
    ("SAM2", "sam2/sam2.1_hiera_tiny.pt",
     "7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69"),
    ("BiRefNet source", f"hf/models--ZhengPeng7--BiRefNet-matting/snapshots/{BIREFNET_REVISION}/model.safetensors",
     "a9875de5b1e6c8eb5fdaa8c727a82927ce442cdc87ba3abee6a77e6fa46c25bb"),
    ("BiRefNet FP16", "birefnet-fp16/model.safetensors",
     "ad4e1bbe79a2f483fe808eaf2ff956183826d42da8d0eeeeacd69f1d80aff1a0"),
    ("Faster R-CNN", "torch/hub/checkpoints/fasterrcnn_resnet50_fpn_v2_coco-dd69338a.pth",
     "dd69338a24b8d7381807e247652bdc356325bcbaf1cd3e092e00e0a1a58706bf"),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_release_assets(weights_dir: Path) -> bool:
    valid = True
    for label, relative_path, expected_digest in ASSETS:
        path = weights_dir / relative_path
        if not path.is_file():
            print(f"missing: {label}: {path}", file=sys.stderr)
            valid = False
            continue
        actual_digest = sha256_file(path)
        if actual_digest != expected_digest:
            print(f"digest mismatch: {label}: expected {expected_digest}, "
                  f"got {actual_digest}", file=sys.stderr)
            valid = False
            continue
        print(f"verified: {label}: {relative_path}")
    return valid


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify all pinned binary model artifacts for a release build.")
    parser.add_argument("--weights-dir", required=True)
    args = parser.parse_args()
    return 0 if verify_release_assets(Path(args.weights_dir)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
