from pathlib import Path
import json
import subprocess
import sys

from PIL import Image, ImageDraw

from pipeline.action_quality import analyze_action_frames, validate_response_candidate
from pipeline.action_prepare import prepare_reaction_sequence
from tests.generate_action_fixture import create_fixture


FIXED_ACTION_KINDS = (
    "gaze_orbit",
    "lie_down",
    "paw",
    "eat",
    "cry",
    "angry_stomp",
    "roll",
    "stretch",
    "sleep_snore",
    "wave",
    "jump_cheer",
    "cuddle",
)


def _write_head_motion_frames(idle, candidate):
    for index in range(8):
        idle_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        idle_draw = ImageDraw.Draw(idle_image)
        idle_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        idle_draw.ellipse((74, 30, 126, 88), fill=(165, 120, 78, 255))
        idle_image.save(idle / f"frame_{index:04d}.png")

        candidate_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        candidate_draw = ImageDraw.Draw(candidate_image)
        candidate_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        head_x = 74 + index * 4
        candidate_draw.ellipse((head_x, 30, head_x + 52, 88), fill=(165, 120, 78, 255))
        candidate_image.save(candidate / f"frame_{index:04d}.png")


def test_validate_action_cli_serializes_numpy_metrics(tmp_path):
    idle = tmp_path / "idle"
    candidate = tmp_path / "candidate"
    idle.mkdir()
    candidate.mkdir()
    _write_head_motion_frames(idle, candidate)

    script = Path(__file__).parents[1] / "scripts" / "validate_action.py"
    completed = subprocess.run(
        [sys.executable, str(script), "--frames-dir", str(candidate),
         "--reference-frames-dir", str(idle), "--kind", "gaze_right"],
        check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    assert payload["type"] == "action_validation"
    assert isinstance(payload["identity"]["passed"], bool)
    assert payload["semantic_review_required"] is True


def test_validate_action_cli_accepts_every_fixed_action_kind(tmp_path):
    idle = tmp_path / "idle"
    candidate = tmp_path / "candidate"
    idle.mkdir()
    candidate.mkdir()
    _write_head_motion_frames(idle, candidate)

    script = Path(__file__).parents[1] / "scripts" / "validate_action.py"
    for kind in FIXED_ACTION_KINDS:
        completed = subprocess.run(
            [sys.executable, str(script), "--frames-dir", str(candidate),
             "--reference-frames-dir", str(idle), "--kind", kind],
            check=True, capture_output=True, text=True)
        payload = json.loads(completed.stdout)
        assert payload["kind"] == kind
        assert payload["semantic_review_required"] is True


def test_synthetic_walk_has_locomotion_evidence(tmp_path):
    create_fixture(tmp_path)
    result = analyze_action_frames(tmp_path / "walk", "walk")
    assert result["passed"], result


def test_static_lower_body_is_rejected_as_walk(tmp_path):
    create_fixture(tmp_path)
    idle = tmp_path / "idle"
    result = analyze_action_frames(idle, "walk")
    assert not result["passed"]
    assert result["reason"] == "no_locomotion_evidence"


def test_missing_frames_fail_closed(tmp_path):
    result = analyze_action_frames(Path(tmp_path), "react")
    assert not result["passed"]
    assert result["reason"] == "too_few_frames"


def test_rigid_camera_pan_does_not_count_as_walking(tmp_path):
    for index in range(8):
        image = Image.new("RGBA", (220, 140), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        offset = index * 8
        draw.rounded_rectangle(
            (20 + offset, 30, 100 + offset, 130),
            radius=20, fill=(100, 160, 230, 255))
        image.save(tmp_path / f"frame_{index:04d}.png")
    result = analyze_action_frames(tmp_path, "walk")
    assert not result["passed"], result


def test_head_only_motion_is_reaction_but_not_walking(tmp_path):
    for index in range(8):
        image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        head_x = 74 + (index % 4) * 8
        draw.ellipse(
            (head_x, 30, head_x + 52, 88), fill=(165, 120, 78, 255))
        image.save(tmp_path / f"frame_{index:04d}.png")

    reaction = analyze_action_frames(tmp_path, "react")
    shaking = analyze_action_frames(tmp_path, "shake_head")
    playing = analyze_action_frames(tmp_path, "play")
    walking = analyze_action_frames(tmp_path, "walk")
    assert reaction["passed"], reaction
    assert shaking["passed"], shaking
    assert not playing["passed"], playing
    assert playing["reason"] == "no_play_evidence"
    assert not walking["passed"], walking


def test_one_way_head_turn_is_not_mislabeled_as_head_shake(tmp_path):
    for index in range(10):
        image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        head_x = 62 + index * 4
        draw.ellipse(
            (head_x, 30, head_x + 52, 88), fill=(165, 120, 78, 255))
        image.save(tmp_path / f"frame_{index:04d}.png")

    reaction = analyze_action_frames(tmp_path, "react", max_frames=None)
    shaking = analyze_action_frames(tmp_path, "shake_head", max_frames=None)
    assert reaction["passed"], reaction
    assert not shaking["passed"], shaking
    assert shaking["reason"] == "no_head_shake_evidence"
    assert shaking["metrics"]["head_direction_reversals"] == 0


def test_play_requires_visible_lower_body_participation(tmp_path):
    for index in range(10):
        image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        bounce = 8 if index % 2 else 0
        draw.rounded_rectangle(
            (45, 55 + bounce, 135, 145 + bounce),
            radius=24, fill=(145, 105, 70, 255))
        draw.rectangle(
            (55 + bounce, 135, 78 + bounce, 170),
            fill=(165, 120, 78, 255))
        draw.rectangle(
            (102 - bounce, 135, 125 - bounce, 170),
            fill=(165, 120, 78, 255))
        image.save(tmp_path / f"frame_{index:04d}.png")

    result = analyze_action_frames(tmp_path, "play", max_frames=None)
    assert result["passed"], result


def test_reaction_preparation_preserves_every_source_frame(tmp_path):
    source = tmp_path / "source"
    output = tmp_path / "prepared"
    source.mkdir()
    for index in range(30):
        image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        head_offset = max(0, 24 - abs(index - 17) * 8)
        draw.ellipse(
            (74 + head_offset, 30, 126 + head_offset, 88),
            fill=(165, 120, 78, 255))
        image.save(source / f"frame_{index:04d}.png")

    prepared = prepare_reaction_sequence(source, output, fps=10)
    assert prepared["prepared"], prepared
    assert prepared["frame_count"] == 30
    assert prepared["source_frame_count"] == 30
    assert prepared["start_index"] == 0
    assert prepared["end_index"] == 30
    assert [path.name for path in sorted(output.glob("frame_*.png"))] == [
        f"frame_{index:04d}.png" for index in range(30)
    ]
    validation = analyze_action_frames(output, "react", max_frames=None)
    assert validation["passed"], validation


def test_small_isolated_edge_noise_is_not_a_reaction(tmp_path):
    for index in range(12):
        image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle(
            (50, 40, 130, 165), radius=22, fill=(145, 105, 70, 255))
        if index in {3, 7, 10}:
            draw.rectangle((131, 80, 132, 81), fill=(145, 105, 70, 255))
        image.save(tmp_path / f"frame_{index:04d}.png")
    result = analyze_action_frames(tmp_path, "react", max_frames=None)
    assert not result["passed"], result


def test_gaze_response_requires_motion_and_owner_appearance_continuity(tmp_path):
    idle = tmp_path / "idle"
    candidate = tmp_path / "candidate"
    idle.mkdir()
    candidate.mkdir()
    for index in range(8):
        idle_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        idle_draw = ImageDraw.Draw(idle_image)
        idle_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        idle_draw.ellipse((74, 30, 126, 88), fill=(165, 120, 78, 255))
        idle_image.save(idle / f"frame_{index:04d}.png")

        gaze_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        gaze_draw = ImageDraw.Draw(gaze_image)
        gaze_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        head_x = 74 + index * 4
        gaze_draw.ellipse((head_x, 30, head_x + 52, 88), fill=(165, 120, 78, 255))
        gaze_image.save(candidate / f"frame_{index:04d}.png")

    result = validate_response_candidate(candidate, "gaze_right", idle)
    assert result["passed"], result
    assert result["identity"]["passed"]
    assert result["metrics"]["identity_similarity"] >= 0.52


def test_response_rejects_different_pet_appearance(tmp_path):
    idle = tmp_path / "idle"
    candidate = tmp_path / "candidate"
    idle.mkdir()
    candidate.mkdir()
    for index in range(8):
        idle_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        idle_draw = ImageDraw.Draw(idle_image)
        idle_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(145, 105, 70, 255))
        idle_draw.ellipse((74, 30, 126, 88), fill=(165, 120, 78, 255))
        idle_image.save(idle / f"frame_{index:04d}.png")

        candidate_image = Image.new("RGBA", (180, 180), (0, 0, 0, 0))
        candidate_draw = ImageDraw.Draw(candidate_image)
        candidate_draw.rounded_rectangle(
            (50, 70, 130, 165), radius=22, fill=(50, 120, 220, 255))
        head_x = 74 + index * 4
        candidate_draw.ellipse((head_x, 30, head_x + 52, 88), fill=(45, 180, 235, 255))
        candidate_image.save(candidate / f"frame_{index:04d}.png")

    result = validate_response_candidate(candidate, "gaze_right", idle)
    assert not result["passed"]
    assert result["reason"] == "identity_mismatch"
