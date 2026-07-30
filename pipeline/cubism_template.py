"""Bind generated pet parts to a precompiled quadruped Cubism template."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path

from PIL import Image

from pipeline.cubism_model import validate_cubism_model
from pipeline.rig_assets import parts_for_template


TEMPLATE_DESCRIPTOR = "realpet-template.json"
TEMPLATE_PROVENANCE = "realpet-provenance.json"
SUPPORTED_TEMPLATE_PROFILES = {
    "cat-v1", "dog-long-snout-v1", "dog-short-snout-v1",
}
CAPABILITY_PARAMETERS = {
    "headPose": {
        "ParamAngleX", "ParamAngleY", "ParamAngleZ", "ParamBodyAngleX",
    },
    "eyeGaze": {
        "ParamEyeBallX", "ParamEyeBallY", "ParamEyeLOpen", "ParamEyeROpen",
    },
    "breathing": {"ParamBreath"},
    "locomotion": {
        "ParamBodyAngleY", "ParamBodyAngleZ", "ParamBodyY", "ParamTail",
        "ParamLegFrontL", "ParamPawFrontL",
        "ParamLegFrontR", "ParamPawFrontR",
        "ParamLegHindL", "ParamPawHindL",
        "ParamLegHindR", "ParamPawHindR",
    },
    "reaction": {
        "ParamBodyAngleZ", "ParamBodyY", "ParamEarL", "ParamEarR", "ParamTail",
        "ParamMouthOpenY",
    },
}


def _load_json(path, label):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError(f"invalid {label}") from error
    if not isinstance(value, dict):
        raise ValueError(f"invalid {label}")
    return value


def _resolve_file(root, relative, label):
    if not isinstance(relative, str) or not relative:
        raise ValueError(f"missing {label}")
    root = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root, relative))
    try:
        if os.path.commonpath([root, candidate]) != root:
            raise ValueError(f"{label} escapes template")
    except ValueError as error:
        raise ValueError(f"{label} escapes template") from error
    if not os.path.isfile(candidate):
        raise ValueError(f"missing {label}: {relative}")
    return Path(candidate)


def _validate_template_tree(template_dir):
    for root, directories, files in os.walk(template_dir, followlinks=False):
        for name in directories + files:
            if (Path(root) / name).is_symlink():
                raise ValueError("Cubism template must not contain symbolic links")


def _validated_slot(slot, texture_size, name):
    if not isinstance(slot, dict) or set(slot) - {"rect", "rotation"}:
        raise ValueError(f"invalid texture slot: {name}")
    rect = slot.get("rect")
    if (not isinstance(rect, list) or len(rect) != 4
            or any(not isinstance(value, int) for value in rect)):
        raise ValueError(f"invalid texture slot rectangle: {name}")
    x, y, width, height = rect
    texture_width, texture_height = texture_size
    if (x < 0 or y < 0 or width <= 0 or height <= 0
            or x + width > texture_width or y + height > texture_height):
        raise ValueError(f"texture slot is out of bounds: {name}")
    rotation = slot.get("rotation", 0)
    if rotation not in (0, 90, 180, 270):
        raise ValueError(f"invalid texture slot rotation: {name}")
    return (x, y, width, height), rotation


def validate_cubism_template(template_dir):
    template_dir = Path(template_dir).resolve()
    _validate_template_tree(template_dir)
    descriptor = _load_json(
        template_dir / TEMPLATE_DESCRIPTOR, "Cubism template descriptor")
    if descriptor.get("version") not in (1, 2):
        raise ValueError("unsupported Cubism template version")
    template_id = descriptor.get("id")
    if not isinstance(template_id, str) or not template_id:
        raise ValueError("missing Cubism template id")
    contract = descriptor.get("contract", template_id)
    parts = parts_for_template(contract)
    profile = descriptor.get("profile")
    if descriptor.get("version") == 2:
        if profile not in SUPPORTED_TEMPLATE_PROFILES:
            raise ValueError("unsupported Cubism template profile")
        if template_id != profile:
            raise ValueError("Cubism template id and profile must match")
        if contract != "quadruped-v2":
            raise ValueError("Cubism template profile must use quadruped-v2")

        provenance = _load_json(
            template_dir / TEMPLATE_PROVENANCE,
            "Cubism template provenance")
        source_project = provenance.get("sourceProject")
        if (provenance.get("schemaVersion") != 1
                or provenance.get("profile") != profile
                or provenance.get("status") != "exported-and-verified"
                or not isinstance(provenance.get("owner"), str)
                or not provenance["owner"].strip()
                or provenance.get("originalWork") is not True
                or provenance.get("thirdPartyCharacterAssets") != []
                or not isinstance(source_project, dict)
                or set(source_project) != {"path", "sha256"}
                or not isinstance(source_project["path"], str)
                or not source_project["path"]
                or not isinstance(source_project["sha256"], str)
                or len(source_project["sha256"]) != 64
                or any(character not in "0123456789abcdef"
                       for character in source_project["sha256"])):
            raise ValueError("invalid Cubism template provenance")
    else:
        provenance = None

    model = _resolve_file(template_dir, descriptor.get("model"), "model")
    package = validate_cubism_model(model)
    model_json = _load_json(model, "Cubism model")
    texture = _resolve_file(
        template_dir, descriptor.get("texture"), "template texture")
    if str(texture) not in package["textures"]:
        raise ValueError("template texture is not referenced by model3.json")
    if texture.suffix.lower() != ".png":
        raise ValueError("template texture must be PNG")

    texture_size = descriptor.get("textureSize")
    if (not isinstance(texture_size, list) or len(texture_size) != 2
            or any(not isinstance(value, int) for value in texture_size)
            or not all(256 <= value <= 8192 for value in texture_size)):
        raise ValueError("invalid template textureSize")
    if descriptor.get("version") == 2:
        if texture_size != [2000, 1600]:
            raise ValueError("built-in template textureSize must be 2000x1600")
        if len(package["textures"]) != 1:
            raise ValueError("built-in template must use exactly one texture")
    try:
        with Image.open(texture) as image:
            if image.size != tuple(texture_size):
                raise ValueError("template textureSize does not match texture file")
    except OSError as error:
        raise ValueError("invalid template texture") from error
    slots = descriptor.get("slots")
    if not isinstance(slots, dict) or set(slots) != set(parts):
        raise ValueError("template slots do not match generated quadruped parts")
    validated_slots = {
        name: _validated_slot(slots[name], texture_size, name)
        for name in parts
    }

    occupied = []
    for name, (rect, _) in validated_slots.items():
        x, y, width, height = rect
        for other_name, other in occupied:
            ox, oy, ow, oh = other
            if x < ox + ow and x + width > ox and y < oy + oh and y + height > oy:
                raise ValueError(f"texture slots overlap: {other_name}, {name}")
        occupied.append((name, rect))

    part_drawables = descriptor.get("partDrawables")
    if contract == "quadruped-v2" or part_drawables is not None:
        if (not isinstance(part_drawables, dict)
                or set(part_drawables) != set(parts)
                or any(not isinstance(value, str) or not value
                       for value in part_drawables.values())
                or len(set(part_drawables.values())) != len(parts)):
            raise ValueError(
                "template partDrawables must uniquely map every generated part")
    else:
        part_drawables = {}

    capabilities = descriptor.get("capabilities")
    required_capabilities = {
        "headPose", "eyeGaze", "breathing", "locomotion", "reaction",
    }
    if (not isinstance(capabilities, dict)
            or set(capabilities) != required_capabilities
            or any(not isinstance(value, bool) for value in capabilities.values())):
        raise ValueError("invalid Cubism template capabilities")

    parameters = descriptor.get("parameters")
    if (not isinstance(parameters, list)
            or any(not isinstance(value, str) or not value for value in parameters)
            or len(parameters) != len(set(parameters))):
        raise ValueError("invalid Cubism template parameters")
    parameter_set = set(parameters)
    for capability, required in CAPABILITY_PARAMETERS.items():
        if capabilities[capability] and not required.issubset(parameter_set):
            missing = ", ".join(sorted(required - parameter_set))
            raise ValueError(
                f"Cubism template capability {capability} lacks parameters: {missing}")

    semantic_motions = descriptor.get("semanticMotions", {})
    allowed_semantics = {"idle", "walk", "react", "shake_head", "play"}
    if (not isinstance(semantic_motions, dict)
            or not set(semantic_motions).issubset(allowed_semantics)
            or any(not isinstance(value, str) or not value
                   for value in semantic_motions.values())):
        raise ValueError("invalid Cubism template semanticMotions")
    model_motions = model_json.get("FileReferences", {}).get("Motions", {})
    for semantic, group in semantic_motions.items():
        if not isinstance(model_motions.get(group), list) or not model_motions[group]:
            raise ValueError(
                f"Cubism template {semantic} motion group is missing: {group}")

    return {
        "root": template_dir,
        "id": template_id,
        "contract": contract,
        "profile": profile,
        "provenance": provenance,
        "model": model,
        "modelRelative": str(model.relative_to(template_dir)),
        "texture": texture,
        "textureRelative": str(texture.relative_to(template_dir)),
        "textureSize": tuple(texture_size),
        "slots": validated_slots,
        "partDrawables": part_drawables,
        "capabilities": capabilities,
        "parameters": parameters,
        "semanticMotions": semantic_motions,
        "parts": parts,
    }


def _render_texture(rig_dir, template):
    texture = Image.new("RGBA", template["textureSize"], (0, 0, 0, 0))
    for name in template["parts"]:
        part_path = rig_dir / "parts" / f"{name}.png"
        if not part_path.is_file():
            raise ValueError(f"missing generated part: {name}")
        part = Image.open(part_path).convert("RGBA")
        rect, rotation = template["slots"][name]
        if rotation:
            part = part.rotate(-rotation, expand=True, resample=Image.Resampling.BICUBIC)
        x, y, width, height = rect
        scale = min(width / part.width, height / part.height)
        size = (
            max(1, round(part.width * scale)),
            max(1, round(part.height * scale)),
        )
        part = part.resize(size, Image.Resampling.LANCZOS)
        position = (x + (width - size[0]) // 2, y + (height - size[1]) // 2)
        texture.alpha_composite(part, position)
    return texture


def install_cubism_template(rig_dir, template_dir):
    rig_dir = Path(rig_dir).resolve()
    manifest_path = rig_dir / "rig.json"
    manifest = _load_json(manifest_path, "rig manifest")
    if manifest.get("stage") != "partsPrepared":
        raise ValueError("rig must be at partsPrepared stage")
    template = validate_cubism_template(template_dir)
    if manifest.get("template") != template["contract"]:
        raise ValueError("rig and Cubism template identifiers do not match")
    if set(manifest.get("parts", {})) != set(template["parts"]):
        raise ValueError("rig parts do not match quadruped template contract")
    next_dir = Path(tempfile.mkdtemp(prefix="model-next-", dir=rig_dir))
    final_dir = rig_dir / "model"
    backup_dir = rig_dir / "model-backup"
    try:
        shutil.copytree(template["root"], next_dir, dirs_exist_ok=True)
        generated_texture = _render_texture(rig_dir, template)
        texture_path = next_dir / template["textureRelative"]
        generated_texture.save(texture_path, format="PNG", optimize=True)
        validate_cubism_model(next_dir / template["modelRelative"])

        if backup_dir.exists():
            shutil.rmtree(backup_dir)
        if final_dir.exists():
            final_dir.rename(backup_dir)
        try:
            next_dir.rename(final_dir)
        except Exception:
            if backup_dir.exists() and not final_dir.exists():
                backup_dir.rename(final_dir)
            raise
        if backup_dir.exists():
            shutil.rmtree(backup_dir)

        manifest.update({
            "stage": "cubismCompiled",
            "template": template["id"],
            "templateContract": template["contract"],
            "templateProfile": template["profile"],
            "model": f"model/{template['modelRelative']}",
            "capabilities": template["capabilities"],
        })
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True),
            encoding="utf-8")
        return manifest_path
    finally:
        if next_dir.exists():
            shutil.rmtree(next_dir)
