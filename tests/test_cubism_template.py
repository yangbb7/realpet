import json

import numpy as np
import pytest
from PIL import Image, ImageDraw

from pipeline.cubism_template import (
    CAPABILITY_PARAMETERS,
    install_cubism_template,
    validate_cubism_template,
)
from pipeline.rig_assets import PARTS, RIG_LAYOUTS, prepare_rig_atlas
from scripts.promote_cubism_template import promote_template


def _write_generated_rig(root):
    atlas = root / "source-atlas.png"
    image = Image.new("RGB", (1200, 1200), (0, 255, 0))
    draw = ImageDraw.Draw(image)
    columns, rows, _ = RIG_LAYOUTS["quadruped-v2"]
    cell_width = image.width // columns
    cell_height = image.height // rows
    for index, _ in enumerate(PARTS):
        column = index % columns
        row = index // columns
        draw.ellipse((
            column * cell_width + 45, row * cell_height + 55,
            (column + 1) * cell_width - 45,
            (row + 1) * cell_height - 55,
        ), fill=(80 + index * 5, 60 + index * 4, 50 + index * 3))
    image.save(atlas)
    rig = root / "rig"
    prepare_rig_atlas(atlas, rig)
    return rig


def _write_template(root, overlapping=False, profile=None):
    template = root / "template"
    (template / "textures").mkdir(parents=True)
    (template / "pet.moc3").write_bytes(b"moc")
    texture_size = (2000, 1600) if profile else (1280, 1024)
    Image.new("RGBA", texture_size, (0, 0, 0, 0)).save(
        template / "textures" / "pet.png")
    (template / "motions").mkdir()
    for name in ("idle", "walk", "react"):
        (template / "motions" / f"{name}.motion3.json").write_text("{}")
    model = {
        "Version": 3,
        "FileReferences": {
            "Moc": "pet.moc3",
            "Textures": ["textures/pet.png"],
            "Motions": {
                "Idle": [{"File": "motions/idle.motion3.json"}],
                "Walk": [{"File": "motions/walk.motion3.json"}],
                "React": [{"File": "motions/react.motion3.json"}],
            },
        },
    }
    (template / "pet.model3.json").write_text(json.dumps(model))
    slots = {}
    for index, name in enumerate(PARTS):
        column = index % 5
        row = index // 5
        cell_size = 400 if profile else 256
        part_size = 400 if profile else 224
        slots[name] = {
            "rect": [column * cell_size, row * cell_size, part_size, part_size]
        }
    if overlapping:
        slots[PARTS[1]] = slots[PARTS[0]]
    descriptor = {
        "version": 2 if profile else 1,
        "id": profile or "quadruped-v2",
        "model": "pet.model3.json",
        "texture": "textures/pet.png",
        "textureSize": list(texture_size),
        "slots": slots,
        "partDrawables": {
            name: f"Drawable_{name}" for name in PARTS
        },
        "capabilities": {
            "headPose": True,
            "eyeGaze": True,
            "breathing": True,
            "locomotion": True,
            "reaction": True,
        },
        "parameters": sorted(set().union(*CAPABILITY_PARAMETERS.values())),
        "semanticMotions": {
            "idle": "Idle",
            "walk": "Walk",
            "react": "React",
        },
    }
    if profile:
        descriptor["contract"] = "quadruped-v2"
        descriptor["profile"] = profile
        (template / "realpet-provenance.json").write_text(json.dumps({
            "schemaVersion": 1,
            "profile": profile,
            "status": "exported-and-verified",
            "owner": "RealPet",
            "originalWork": True,
            "thirdPartyCharacterAssets": [],
            "sourceProject": {
                "path": f"artifacts/cubism-template-sources/{profile}.cmo3",
                "sha256": "0" * 64,
            },
        }))
    (template / "realpet-template.json").write_text(json.dumps(descriptor))
    return template


@pytest.mark.parametrize(
    "profile", ["cat-v1", "dog-long-snout-v1", "dog-short-snout-v1"])
def test_v2_profile_template_validates_and_installs(profile, tmp_path):
    rig = _write_generated_rig(tmp_path)
    template = _write_template(tmp_path, profile=profile)

    validated = validate_cubism_template(template)
    assert validated["contract"] == "quadruped-v2"
    assert validated["profile"] == profile

    manifest = json.loads(install_cubism_template(rig, template).read_text())
    assert manifest["template"] == profile
    assert manifest["templateContract"] == "quadruped-v2"
    assert manifest["templateProfile"] == profile


def test_v2_profile_template_requires_original_asset_provenance(tmp_path):
    template = _write_template(tmp_path, profile="cat-v1")
    (template / "realpet-provenance.json").unlink()

    with pytest.raises(ValueError, match="provenance"):
        validate_cubism_template(template)


@pytest.mark.parametrize(
    ("capability", "parameter"),
    [
        ("headPose", "ParamAngleZ"),
        ("eyeGaze", "ParamEyeLOpen"),
        ("eyeGaze", "ParamEyeROpen"),
        ("reaction", "ParamMouthOpenY"),
    ],
)
def test_v2_template_rejects_claimed_capability_without_required_parameter(
        capability, parameter, tmp_path):
    template = _write_template(tmp_path, profile="cat-v1")
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    descriptor["parameters"].remove(parameter)
    descriptor_path.write_text(json.dumps(descriptor))

    with pytest.raises(
            ValueError, match=rf"{capability}.*{parameter}|{parameter}.*{capability}"):
        validate_cubism_template(template)


def test_internal_export_is_atomically_promoted_with_source_hash(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    export = _write_template(
        tmp_path / "export-fixture", profile="cat-v1")
    source = project / "artifacts" / "cat-source.cmo3"
    source.parent.mkdir()
    source.write_bytes(b"original cubism source")

    destination = promote_template(
        project_root=project,
        profile="cat-v1",
        export_dir=export,
        descriptor_path=export / "realpet-template.json",
        source_cmo3=source,
        model_relative="pet.model3.json",
        texture_relative="textures/pet.png")

    validated = validate_cubism_template(destination)
    assert validated["profile"] == "cat-v1"
    assert validated["provenance"]["status"] == "exported-and-verified"
    assert validated["provenance"]["sourceProject"]["path"] \
        == "artifacts/cat-source.cmo3"


def test_template_promotion_rejects_source_outside_repository(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    export = _write_template(
        tmp_path / "export-fixture", profile="cat-v1")
    source = tmp_path / "outside.cmo3"
    source.write_bytes(b"outside")

    with pytest.raises(ValueError, match="inside repository"):
        promote_template(
            project_root=project,
            profile="cat-v1",
            export_dir=export,
            descriptor_path=export / "realpet-template.json",
            source_cmo3=source,
            model_relative="pet.model3.json",
            texture_relative="textures/pet.png")


def test_install_template_composes_texture_and_unlocks_real_capabilities(tmp_path):
    rig = _write_generated_rig(tmp_path)
    template = _write_template(tmp_path)

    manifest_path = install_cubism_template(rig, template)
    manifest = json.loads(manifest_path.read_text())

    assert manifest["stage"] == "cubismCompiled"
    assert manifest["model"] == "model/pet.model3.json"
    assert manifest["template"] == "quadruped-v2"
    assert all(manifest["capabilities"].values())
    texture = Image.open(rig / "model" / "textures" / "pet.png").convert("RGBA")
    assert texture.size == (1280, 1024)
    assert np.asarray(texture.getchannel("A")).max() == 255


def test_prepared_atlas_can_compile_later_without_regenerating_parts(tmp_path):
    prepared = _write_generated_rig(tmp_path)
    template = _write_template(tmp_path)
    compiled = tmp_path / "compiled-from-existing-atlas"

    prepare_rig_atlas(prepared / "atlas.png", compiled)
    manifest_path = install_cubism_template(compiled, template)
    manifest = json.loads(manifest_path.read_text())
    original = json.loads((prepared / "rig.json").read_text())

    assert original["stage"] == "partsPrepared"
    assert manifest["stage"] == "cubismCompiled"
    assert manifest["sourceModel"] == "gpt-image-2"
    assert set(manifest["parts"]) == set(PARTS)
    assert (compiled / manifest["model"]).is_file()


def test_template_rejects_overlapping_uv_slots(tmp_path):
    template = _write_template(tmp_path, overlapping=True)

    with pytest.raises(ValueError, match="texture slots overlap"):
        validate_cubism_template(template)


def test_v2_template_requires_one_unique_drawable_per_part(tmp_path):
    template = _write_template(tmp_path)
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    descriptor["partDrawables"]["nose"] = descriptor["partDrawables"]["muzzle"]
    descriptor_path.write_text(json.dumps(descriptor))

    with pytest.raises(ValueError, match="uniquely map every generated part"):
        validate_cubism_template(template)

    descriptor["partDrawables"].pop("nose")
    descriptor_path.write_text(json.dumps(descriptor))
    with pytest.raises(ValueError, match="uniquely map every generated part"):
        validate_cubism_template(template)


def test_template_rejects_symlink_escape(tmp_path):
    template = _write_template(tmp_path)
    outside = tmp_path / "outside"
    outside.write_text("outside")
    (template / "linked").symlink_to(outside)

    with pytest.raises(ValueError, match="symbolic links"):
        validate_cubism_template(template)


def test_template_rejects_claimed_motion_group_that_is_not_in_model(tmp_path):
    template = _write_template(tmp_path)
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    descriptor["semanticMotions"]["walk"] = "MissingWalk"
    descriptor_path.write_text(json.dumps(descriptor))

    with pytest.raises(ValueError, match="walk motion group is missing"):
        validate_cubism_template(template)


def test_template_accepts_parameter_driven_actions_without_motion_files(tmp_path):
    template = _write_template(tmp_path)
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    descriptor["semanticMotions"] = {}
    descriptor_path.write_text(json.dumps(descriptor))

    model_path = template / descriptor["model"]
    model = json.loads(model_path.read_text())
    model["FileReferences"].pop("Motions")
    model_path.write_text(json.dumps(model))

    validated = validate_cubism_template(template)
    assert validated["semanticMotions"] == {}


def test_template_accepts_optional_exact_reaction_motions(tmp_path):
    template = _write_template(tmp_path)
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    model_path = template / descriptor["model"]
    model = json.loads(model_path.read_text())
    model["FileReferences"]["Motions"]["Play"] = [
        {"File": "motions/react.motion3.json"}
    ]
    model["FileReferences"]["Motions"]["ShakeHead"] = [
        {"File": "motions/react.motion3.json"}
    ]
    model_path.write_text(json.dumps(model))
    descriptor["semanticMotions"].update({
        "play": "Play", "shake_head": "ShakeHead",
    })
    descriptor_path.write_text(json.dumps(descriptor))

    validated = validate_cubism_template(template)
    assert validated["semanticMotions"]["play"] == "Play"
    assert validated["semanticMotions"]["shake_head"] == "ShakeHead"


def test_template_rejects_unknown_semantic_motion(tmp_path):
    template = _write_template(tmp_path)
    descriptor_path = template / "realpet-template.json"
    descriptor = json.loads(descriptor_path.read_text())
    descriptor["semanticMotions"]["dance"] = "React"
    descriptor_path.write_text(json.dumps(descriptor))

    with pytest.raises(ValueError, match="semanticMotions"):
        validate_cubism_template(template)


def test_template_install_rejects_any_missing_independent_part(tmp_path):
    rig = _write_generated_rig(tmp_path)
    template = _write_template(tmp_path)
    (rig / "parts" / "nose.png").unlink()

    with pytest.raises(ValueError, match="missing generated part: nose"):
        install_cubism_template(rig, template)
