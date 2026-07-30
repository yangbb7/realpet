#!/usr/bin/env python3
"""Promote an internally authored Cubism export into a built-in template."""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from pipeline.cubism_template import (  # noqa: E402
    SUPPORTED_TEMPLATE_PROFILES,
    validate_cubism_template,
)


def _load_object(path, label):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError(f"invalid {label}") from error
    if not isinstance(value, dict):
        raise ValueError(f"invalid {label}")
    return value


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _reject_symlinks(root):
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            if (Path(directory) / name).is_symlink():
                raise ValueError("Cubism export must not contain symbolic links")


def promote_template(
        project_root, profile, export_dir, descriptor_path, source_cmo3,
        model_relative, texture_relative, replace=False):
    project_root = Path(project_root).resolve()
    export_dir = Path(export_dir).resolve()
    source_cmo3 = Path(source_cmo3).resolve()
    if profile not in SUPPORTED_TEMPLATE_PROFILES:
        raise ValueError(f"unsupported Cubism template profile: {profile}")
    if not export_dir.is_dir():
        raise ValueError("missing Cubism export directory")
    if not source_cmo3.is_file() or source_cmo3.suffix.lower() != ".cmo3":
        raise ValueError("missing original .cmo3 source project")
    try:
        source_relative = source_cmo3.relative_to(project_root)
    except ValueError as error:
        raise ValueError("original .cmo3 source project must be inside repository") from error
    _reject_symlinks(export_dir)

    descriptor = _load_object(descriptor_path, "template authoring descriptor")
    descriptor.update({
        "version": 2,
        "id": profile,
        "profile": profile,
        "contract": "quadruped-v2",
        "model": model_relative,
        "texture": texture_relative,
    })

    templates_root = project_root / "assets" / "cubism-templates"
    templates_root.mkdir(parents=True, exist_ok=True)
    destination = templates_root / profile
    if destination.exists() and not replace:
        raise ValueError(f"built-in template already exists: {profile}")
    staging = Path(tempfile.mkdtemp(prefix=f".{profile}-", dir=templates_root))
    backup = templates_root / f".{profile}-backup"
    try:
        shutil.copytree(export_dir, staging, dirs_exist_ok=True)
        (staging / "realpet-template.json").write_text(
            json.dumps(descriptor, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
        provenance = {
            "schemaVersion": 1,
            "profile": profile,
            "status": "exported-and-verified",
            "owner": "RealPet",
            "originalWork": True,
            "thirdPartyCharacterAssets": [],
            "sourceProject": {
                "path": source_relative.as_posix(),
                "sha256": _sha256(source_cmo3),
            },
        }
        (staging / "realpet-provenance.json").write_text(
            json.dumps(provenance, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
        validated = validate_cubism_template(staging)
        if validated["profile"] != profile:
            raise ValueError("promoted Cubism template profile mismatch")

        if backup.exists():
            shutil.rmtree(backup)
        if destination.exists():
            destination.rename(backup)
        try:
            staging.rename(destination)
        except Exception:
            if backup.exists() and not destination.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        return destination
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", default=PROJECT_ROOT)
    parser.add_argument("--profile", required=True,
                        choices=sorted(SUPPORTED_TEMPLATE_PROFILES))
    parser.add_argument("--export-dir", required=True)
    parser.add_argument("--descriptor", required=True)
    parser.add_argument("--source-cmo3", required=True)
    parser.add_argument("--model-relative", required=True)
    parser.add_argument("--texture-relative", required=True)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        destination = promote_template(
            args.project_root, args.profile, args.export_dir, args.descriptor,
            args.source_cmo3, args.model_relative, args.texture_relative,
            replace=args.replace)
        print(json.dumps({
            "type": "cubism_template_promoted",
            "profile": args.profile,
            "destination": str(destination),
        }))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "type": "cubism_template_promoted",
            "profile": args.profile,
            "message": str(error),
        }))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
