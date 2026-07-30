import json

import numpy as np
import pytest
from PIL import Image, ImageDraw

from pipeline.rig_assets import (
    LEGACY_PARTS,
    PARTS,
    RIG_LAYOUTS,
    parts_for_template,
    prepare_rig_atlas,
)


def _write_fixture(path, touch_edge=False, merge_components=False):
    image = Image.new("RGB", (1200, 1200), (0, 255, 0))
    draw = ImageDraw.Draw(image)
    columns, rows, _ = RIG_LAYOUTS["quadruped-v2"]
    cell_width = image.width // columns
    cell_height = image.height // rows
    for index, _ in enumerate(PARTS):
        column = index % columns
        row = index // columns
        x0 = column * cell_width + 40
        y0 = row * cell_height + 60
        x1 = (column + 1) * cell_width - 40
        y1 = (row + 1) * cell_height - 60
        if touch_edge and index == 0:
            x0 = 0
        color = (40 + index * 12, 45 + index * 7, 55 + index * 5)
        draw.ellipse((x0, y0, x1, y1), fill=color)
    if merge_components:
        draw.rectangle((cell_width - 45, 120, cell_width + 45, 180), fill=(80, 90, 100))
    image.save(path)


def test_prepare_rig_atlas_splits_parts_and_keeps_capability_locked(tmp_path):
    atlas = tmp_path / "atlas.png"
    output = tmp_path / "rig"
    _write_fixture(atlas)

    manifest_path = prepare_rig_atlas(atlas, output)
    manifest = json.loads(manifest_path.read_text())

    assert manifest["targetRenderer"] == "live2dCubism"
    assert manifest["stage"] == "partsPrepared"
    assert manifest["template"] == "quadruped-v2"
    assert manifest["partContract"] == 2
    assert manifest["grid"] == {"columns": 5, "rows": 4}
    assert manifest["normalizedLayout"] is False
    assert manifest["capabilities"] == {
        "headPose": False,
        "eyeGaze": False,
        "breathing": False,
        "locomotion": False,
        "reaction": False,
    }
    assert set(manifest["parts"]) == set(PARTS)
    assert manifest["parts"]["nose"] == "parts/nose.png"
    for relative_path in manifest["parts"].values():
        part = Image.open(output / relative_path)
        assert part.mode == "RGBA"
        alpha = np.asarray(part.getchannel("A"))
        assert alpha.max() == 255
        assert alpha[0, 0] == 0
        rgba = np.asarray(part)
        edge = (alpha > 0) & (alpha < 224)
        assert np.all(rgba[:, :, 1][edge] <= np.maximum(
            rgba[:, :, 0][edge], rgba[:, :, 2][edge]) + 1)


def test_prepare_rig_atlas_normalizes_isolated_components_crossing_cells(tmp_path):
    atlas = tmp_path / "near-grid-atlas.png"
    _write_fixture(atlas, touch_edge=True)

    manifest_path = prepare_rig_atlas(atlas, tmp_path / "rig")
    manifest = json.loads(manifest_path.read_text())

    assert manifest["normalizedLayout"] is True
    assert len(manifest["parts"]) == 20


def test_prepare_rig_atlas_rejects_merged_components(tmp_path):
    atlas = tmp_path / "bad-atlas.png"
    _write_fixture(atlas, touch_edge=True, merge_components=True)

    with pytest.raises(ValueError, match="cannot be normalized safely"):
        prepare_rig_atlas(atlas, tmp_path / "rig")


def test_legacy_part_contract_remains_identifiable():
    assert parts_for_template("quadruped-v1") == LEGACY_PARTS
    assert len(LEGACY_PARTS) == 16
    assert "nose" not in LEGACY_PARTS
    assert len(parts_for_template("quadruped-v2")) == 20
    assert "nose" in parts_for_template("quadruped-v2")
