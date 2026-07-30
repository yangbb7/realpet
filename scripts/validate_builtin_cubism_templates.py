#!/usr/bin/env python3
"""Validate all release templates and their original Cubism source projects."""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from pipeline.cubism_template import (  # noqa: E402
    SUPPORTED_TEMPLATE_PROFILES,
    validate_cubism_template,
)


def _contained_source(project_root, relative_path):
    project_root = project_root.resolve()
    source = (project_root / relative_path).resolve()
    try:
        if os.path.commonpath((project_root, source)) != str(project_root):
            raise ValueError("Cubism source project escapes repository")
    except ValueError as error:
        raise ValueError("Cubism source project escapes repository") from error
    if not source.is_file() or source.suffix.lower() != ".cmo3":
        raise ValueError(f"missing original Cubism source project: {relative_path}")
    return source


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_builtin_templates(project_root):
    project_root = Path(project_root).resolve()
    templates_root = project_root / "assets" / "cubism-templates"
    results = []
    for profile in sorted(SUPPORTED_TEMPLATE_PROFILES):
        template = validate_cubism_template(templates_root / profile)
        if template["profile"] != profile:
            raise ValueError(f"built-in Cubism profile mismatch: {profile}")
        source_record = template["provenance"]["sourceProject"]
        source = _contained_source(project_root, source_record["path"])
        actual_hash = _sha256(source)
        if actual_hash != source_record["sha256"]:
            raise ValueError(f"Cubism source project hash mismatch: {profile}")
        results.append({
            "profile": profile,
            "sourceProject": str(source.relative_to(project_root)),
            "sourceSHA256": actual_hash,
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        templates = validate_builtin_templates(args.project_root)
        print(json.dumps({
            "type": "builtin_cubism_templates_validated",
            "valid": True,
            "templates": templates,
        }))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "type": "builtin_cubism_templates_validated",
            "valid": False,
            "message": str(error),
        }))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
