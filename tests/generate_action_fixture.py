"""Generate a tiny transparent multi-action pet for local runtime checks."""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def create_fixture(root):
    root = Path(root)
    specs = {
        "idle": ("idle", False, (50, 130, 230, 255)),
        "walk": ("walk", True, (60, 190, 100, 255)),
        "react": ("react", False, (230, 90, 80, 255)),
    }
    actions = []
    for action_id, (kind, translates, color) in specs.items():
        directory = root / action_id
        directory.mkdir(parents=True, exist_ok=True)
        for index in range(6):
            image = Image.new("RGBA", (180, 140), (0, 0, 0, 0))
            draw = ImageDraw.Draw(image)
            bounce = (index % 2) * 5 if action_id != "idle" else 0
            draw.rounded_rectangle(
                (45, 35 + bounce, 135, 125 + bounce),
                radius=20, fill=color)
            if action_id == "walk":
                leg_shift = 8 if index % 2 else 0
                draw.rectangle((60 + leg_shift, 118, 78 + leg_shift, 138), fill=color)
                draw.rectangle((105 - leg_shift, 118, 123 - leg_shift, 138), fill=color)
            image.save(directory / f"frame_{index:04d}.png")
        actions.append({
            "id": action_id,
            "kind": kind,
            "framesDirectory": action_id,
            "fps": 10 if action_id == "idle" else 12,
            "loop": action_id != "react",
            "translatesWindow": translates,
        })
    (root / "actions.json").write_text(json.dumps({
        "version": 1,
        "defaultAction": "idle",
        "actions": actions,
    }), encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_action_fixture.py OUTPUT_DIR")
    create_fixture(sys.argv[1])
