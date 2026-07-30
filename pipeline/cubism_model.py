"""Validate Live2D Cubism runtime model packages before loading native code."""

from __future__ import annotations

import json
import os
from pathlib import Path


def _resolve_file(root, relative, label):
    if not isinstance(relative, str) or not relative:
        raise ValueError(f"missing {label}")
    root = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root, relative))
    try:
        if os.path.commonpath([root, candidate]) != root:
            raise ValueError(f"{label} escapes model package")
    except ValueError as error:
        raise ValueError(f"{label} escapes model package") from error
    if not os.path.isfile(candidate):
        raise ValueError(f"missing {label}: {relative}")
    return candidate


def validate_cubism_model(model_path):
    model_path = Path(model_path)
    try:
        model = json.loads(model_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError("invalid model3.json") from error
    if not isinstance(model, dict) or model.get("Version") != 3:
        raise ValueError("unsupported model3.json version")
    references = model.get("FileReferences")
    if not isinstance(references, dict):
        raise ValueError("missing FileReferences")

    root = str(model_path.parent)
    moc = _resolve_file(root, references.get("Moc"), "Moc")
    textures = references.get("Textures")
    if not isinstance(textures, list) or not textures:
        raise ValueError("missing Textures")
    resolved_textures = [
        _resolve_file(root, value, f"Texture[{index}]")
        for index, value in enumerate(textures)
    ]

    optional = {}
    for key in ("Physics", "Pose", "DisplayInfo", "UserData"):
        value = references.get(key)
        if value is not None:
            optional[key] = _resolve_file(root, value, key)

    expressions = references.get("Expressions", [])
    if not isinstance(expressions, list):
        raise ValueError("Expressions must be an array")
    for index, expression in enumerate(expressions):
        if not isinstance(expression, dict):
            raise ValueError(f"Expression[{index}] is invalid")
        _resolve_file(root, expression.get("File"), f"Expression[{index}]")

    motions = references.get("Motions", {})
    if not isinstance(motions, dict):
        raise ValueError("Motions must be an object")
    for group, entries in motions.items():
        if not isinstance(entries, list):
            raise ValueError(f"Motion group {group} must be an array")
        for index, motion in enumerate(entries):
            if not isinstance(motion, dict):
                raise ValueError(f"Motion {group}[{index}] is invalid")
            _resolve_file(root, motion.get("File"), f"Motion {group}[{index}]")
            sound = motion.get("Sound")
            if sound is not None:
                _resolve_file(root, sound, f"Sound {group}[{index}]")

    return {
        "model": str(model_path.resolve()),
        "root": root,
        "moc": moc,
        "textures": resolved_textures,
        "optional": optional,
    }
