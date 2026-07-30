#!/usr/bin/env python3
"""Build a layered Cubism authoring PSD from a RealPet original rig package."""

import argparse
import json
from pathlib import Path

from PIL import Image

try:
    from psd_tools import PSDImage
except ImportError as error:
    raise SystemExit(
        "psd-tools is required; run with `uv run --with psd-tools`"
    ) from error


def _placed_layer(part, canvas_size, center, scale):
    part = part.convert("RGBA")
    size = (
        max(1, round(part.width * scale)),
        max(1, round(part.height * scale)),
    )
    part = part.resize(size, Image.Resampling.LANCZOS)
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    position = (
        round(center[0] - part.width / 2),
        round(center[1] - part.height / 2),
    )
    layer.alpha_composite(part, position)
    return layer


def build_psd(package_dir, output_path, preview_path=None):
    package_dir = Path(package_dir)
    spec = json.loads((package_dir / "authoring-spec.json").read_text())
    canvas_size = (spec["canvas"]["width"], spec["canvas"]["height"])
    layout = spec["neutralLayout"]
    parts = sorted(spec["parts"], key=lambda item: item["drawOrder"])

    psd = PSDImage.new(mode="RGB", size=canvas_size, depth=8)
    preview = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    for part_spec in parts:
        name = part_spec["name"]
        placement = layout[name]
        source = package_dir / "rig" / "parts" / f"{name}.png"
        layer_image = _placed_layer(
            Image.open(source), canvas_size,
            placement["center"], placement["scale"])
        layer = psd.create_pixel_layer(
            layer_image, name=part_spec["drawableId"], top=0, left=0)
        layer.visible = placement["visible"]
        if placement["visible"]:
            preview.alpha_composite(layer_image)

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    psd.save(output_path)
    if preview_path:
        preview_path = Path(preview_path)
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        preview.save(preview_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--preview")
    args = parser.parse_args()
    build_psd(args.package_dir, args.output, args.preview)


if __name__ == "__main__":
    main()
