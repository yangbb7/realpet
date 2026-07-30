import json

import pytest

from pipeline.cubism_model import validate_cubism_model


def _write_model(root, moc="pet.moc3"):
    (root / "textures").mkdir()
    (root / "pet.moc3").write_bytes(b"moc")
    (root / "textures" / "pet.png").write_bytes(b"png")
    (root / "idle.motion3.json").write_text("{}")
    model = {
        "Version": 3,
        "FileReferences": {
            "Moc": moc,
            "Textures": ["textures/pet.png"],
            "Motions": {"Idle": [{"File": "idle.motion3.json"}]},
        },
    }
    path = root / "pet.model3.json"
    path.write_text(json.dumps(model))
    return path


def test_valid_cubism_package_resolves_required_runtime_files(tmp_path):
    model = _write_model(tmp_path)
    package = validate_cubism_model(model)

    assert package["moc"].endswith("pet.moc3")
    assert package["textures"][0].endswith("textures/pet.png")


def test_cubism_package_rejects_path_escape(tmp_path):
    outside = tmp_path.parent / "outside.moc3"
    outside.write_bytes(b"moc")
    model = _write_model(tmp_path, moc="../outside.moc3")

    with pytest.raises(ValueError, match="escapes model package"):
        validate_cubism_model(model)


def test_cubism_package_rejects_missing_texture(tmp_path):
    model = _write_model(tmp_path)
    (tmp_path / "textures" / "pet.png").unlink()

    with pytest.raises(ValueError, match="missing Texture"):
        validate_cubism_model(model)
