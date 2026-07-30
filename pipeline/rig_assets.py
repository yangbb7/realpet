"""Validate and split a fixed gpt-image-2 pet rig atlas."""

from __future__ import annotations

import json
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image


LEGACY_PARTS = (
    "head", "muzzle", "eye_left", "eye_right",
    "ear_left", "ear_right", "torso", "tail",
    "front_leg_left", "front_paw_left",
    "front_leg_right", "front_paw_right",
    "hind_leg_left", "hind_paw_left",
    "hind_leg_right", "hind_paw_right",
)
PARTS = (
    "head", "muzzle", "nose", "mouth", "tongue",
    "eye_left", "eye_right", "ear_left", "ear_right", "torso",
    "chest", "tail", "front_leg_left", "front_paw_left",
    "front_leg_right", "front_paw_right", "hind_leg_left",
    "hind_paw_left", "hind_leg_right", "hind_paw_right",
)
RIG_LAYOUTS = {
    "quadruped-v1": (4, 4, LEGACY_PARTS),
    "quadruped-v2": (5, 4, PARTS),
}


def parts_for_template(template):
    try:
        return RIG_LAYOUTS[template][2]
    except (KeyError, TypeError) as error:
        raise ValueError(f"unsupported rig template: {template}") from error


def _sample_border_key(rgb):
    pixels = np.asarray(rgb.convert("RGB"))
    band = max(1, min(rgb.size) // 128)
    samples = np.concatenate((
        pixels[:band].reshape(-1, 3), pixels[-band:].reshape(-1, 3),
        pixels[:, :band].reshape(-1, 3), pixels[:, -band:].reshape(-1, 3),
    ))
    return tuple(int(round(value)) for value in np.median(samples, axis=0))


def _soft_chroma_alpha(rgb, key=(0, 255, 0), transparent=12, opaque=220):
    pixels = np.asarray(rgb, dtype=np.float32)
    key_pixel = np.asarray(key, dtype=np.float32)
    distance = np.max(np.abs(pixels - key_pixel), axis=2)
    ratio = np.clip(
        (distance - transparent) / max(1, opaque - transparent), 0, 1)
    distance_alpha = (ratio * ratio * (3.0 - 2.0 * ratio)) * 255.0

    red, green, blue = (pixels[:, :, channel] for channel in range(3))
    non_key = np.maximum(red, blue)
    dominance = green - non_key
    dominance_alpha = (
        1.0 - np.clip(dominance / np.maximum(1.0, key[1] - non_key), 0, 1)
    ) * 255.0
    key_like = (distance <= 32) | (dominance >= 16)
    alpha = np.where(
        key_like, np.minimum(distance_alpha, dominance_alpha), 255.0)
    alpha = np.where((alpha > 0) & (alpha <= 8), 0, alpha)
    return np.asarray(np.clip(alpha, 0, 255), dtype=np.uint8)


def _despill_chroma(rgb, alpha, key):
    pixels = np.asarray(rgb, dtype=np.float32).copy()
    red = pixels[:, :, 0]
    green = pixels[:, :, 1]
    blue = pixels[:, :, 2]
    non_key = np.maximum(red, blue)
    distance = np.max(
        np.abs(pixels - np.asarray(key, dtype=np.float32)), axis=2)
    key_like = (distance <= 32) | ((green - non_key) >= 16)
    despill = key_like & (alpha < 252)
    pixels[:, :, 1] = np.where(
        despill & (green > non_key), np.maximum(0, non_key - 1), green)
    pixels[alpha == 0] = 0
    return np.asarray(np.clip(pixels, 0, 255), dtype=np.uint8)


def _component_touches_cell_boundary(cell):
    rgb = cell.convert("RGB")
    alpha = _soft_chroma_alpha(rgb, _sample_border_key(rgb))
    foreground = alpha >= 32
    coverage = float(foreground.mean())
    if not 0.01 <= coverage <= 0.75:
        return True
    ys, xs = np.where(foreground)
    if not len(xs):
        return True
    edge_margin = max(2, int(min(cell.size) * 0.015))
    return (
        int(xs.min()) < edge_margin
        or int(ys.min()) < edge_margin
        or int(xs.max()) + 1 > cell.width - edge_margin
        or int(ys.max()) + 1 > cell.height - edge_margin
    )


def _normalize_component_grid(image, columns, rows, component_count):
    """Re-center a model-generated near-grid without guessing merged parts."""
    rgb = image.convert("RGB")
    alpha = _soft_chroma_alpha(rgb, _sample_border_key(rgb))
    mask = np.asarray(alpha >= 32, dtype=np.uint8)
    count, _, stats, centroids = cv2.connectedComponentsWithStats(mask, 8)
    minimum_area = max(64, round(image.width * image.height * 0.0003))
    components = []
    for label in range(1, count):
        x, y, width, height, area = (int(value) for value in stats[label])
        if area >= minimum_area:
            components.append({
                "box": (x, y, width, height),
                "center": (float(centroids[label][0]), float(centroids[label][1])),
            })
    if len(components) != component_count:
        raise ValueError(
            "rig atlas has crossing cells and cannot be normalized safely: "
            f"expected {component_count} isolated components, found {len(components)}")

    components.sort(key=lambda item: item["center"][1])
    ordered = []
    for row in range(rows):
        row_components = components[row * columns:(row + 1) * columns]
        row_components.sort(key=lambda item: item["center"][0])
        ordered.extend(row_components)

    key = (0, 255, 0)
    normalized = Image.new("RGB", image.size, key)
    for index, component in enumerate(ordered):
        x, y, width, height = component["box"]
        margin = max(4, round(max(width, height) * 0.035))
        crop = rgb.crop((
            max(0, x - margin), max(0, y - margin),
            min(rgb.width, x + width + margin),
            min(rgb.height, y + height + margin),
        ))
        column = index % columns
        row = index // columns
        cell_x0 = round(column * image.width / columns)
        cell_x1 = round((column + 1) * image.width / columns)
        cell_y0 = round(row * image.height / rows)
        cell_y1 = round((row + 1) * image.height / rows)
        available_width = max(1, round((cell_x1 - cell_x0) * 0.76))
        available_height = max(1, round((cell_y1 - cell_y0) * 0.76))
        scale = min(available_width / crop.width, available_height / crop.height)
        target_size = (
            max(1, round(crop.width * scale)),
            max(1, round(crop.height * scale)),
        )
        crop = crop.resize(target_size, Image.Resampling.LANCZOS)
        position = (
            cell_x0 + ((cell_x1 - cell_x0) - crop.width) // 2,
            cell_y0 + ((cell_y1 - cell_y0) - crop.height) // 2,
        )
        normalized.paste(crop, position)
    return normalized


def _normalize_if_needed(image, columns, rows, parts):
    for index in range(len(parts)):
        column = index % columns
        row = index // columns
        cell = image.crop((
            round(column * image.width / columns),
            round(row * image.height / rows),
            round((column + 1) * image.width / columns),
            round((row + 1) * image.height / rows),
        ))
        if _component_touches_cell_boundary(cell):
            return _normalize_component_grid(
                image, columns, rows, len(parts)), True
    return image, False


def _prepare_part(cell, name, output_dir):
    rgb = cell.convert("RGB")
    key = _sample_border_key(rgb)
    alpha = _soft_chroma_alpha(rgb, key)
    foreground = alpha >= 32
    coverage = float(foreground.mean())
    if not 0.01 <= coverage <= 0.75:
        raise ValueError(f"{name}: foreground coverage {coverage:.3f} is invalid")

    ys, xs = np.where(foreground)
    if not len(xs):
        raise ValueError(f"{name}: no foreground")
    x0, x1 = int(xs.min()), int(xs.max()) + 1
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    edge_margin = max(2, int(min(cell.size) * 0.015))
    if (x0 < edge_margin or y0 < edge_margin
            or x1 > cell.width - edge_margin
            or y1 > cell.height - edge_margin):
        raise ValueError(f"{name}: component touches its cell boundary")

    margin = max(4, int(max(x1 - x0, y1 - y0) * 0.06))
    box = (
        max(0, x0 - margin), max(0, y0 - margin),
        min(cell.width, x1 + margin), min(cell.height, y1 + margin),
    )
    rgba = np.dstack((_despill_chroma(rgb, alpha, key), alpha))
    result = Image.fromarray(rgba, "RGBA").crop(box)
    path = output_dir / f"{name}.png"
    result.save(path)
    return path.name


def prepare_rig_atlas(
        atlas_path, output_dir, source_model="gpt-image-2",
        template="quadruped-v2"):
    atlas_path = Path(atlas_path)
    output_dir = Path(output_dir)
    image = Image.open(atlas_path).convert("RGB")
    width, height = image.size
    if width < 1024 or height < 1024 or not math.isclose(
            width / height, 1.0, rel_tol=0.02):
        raise ValueError("rig atlas must be square and at least 1024x1024")

    try:
        grid_columns, grid_rows, parts = RIG_LAYOUTS[template]
    except (KeyError, TypeError) as error:
        raise ValueError(f"unsupported rig template: {template}") from error

    image, normalized = _normalize_if_needed(
        image, grid_columns, grid_rows, parts)

    output_dir.mkdir(parents=True, exist_ok=True)
    parts_dir = output_dir / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    part_paths = {}
    for index, name in enumerate(parts):
        column = index % grid_columns
        row = index // grid_columns
        x0 = round(column * width / grid_columns)
        x1 = round((column + 1) * width / grid_columns)
        y0 = round(row * height / grid_rows)
        y1 = round((row + 1) * height / grid_rows)
        cell = image.crop((
            x0, y0, x1, y1,
        ))
        filename = _prepare_part(cell, name, parts_dir)
        part_paths[name] = f"parts/{filename}"

    atlas_destination = output_dir / "atlas.png"
    image.save(atlas_destination)
    manifest = {
        "version": 1,
        "targetRenderer": "live2dCubism",
        "stage": "partsPrepared",
        "sourceModel": source_model,
        "template": template,
        "partContract": 2 if template == "quadruped-v2" else 1,
        "grid": {"columns": grid_columns, "rows": grid_rows},
        "normalizedLayout": normalized,
        "atlas": atlas_destination.name,
        "parts": part_paths,
        "capabilities": {
            "headPose": False,
            "eyeGaze": False,
            "breathing": False,
            "locomotion": False,
            "reaction": False,
        },
    }
    manifest_path = output_dir / "rig.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True),
        encoding="utf-8")
    return manifest_path
