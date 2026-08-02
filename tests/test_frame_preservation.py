"""Regression tests for the no-frame-loss import contract."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from scripts.track_then_matte import extract_frames, _verify_output_frame_sequence


def test_extraction_keeps_every_decoded_frame(tmp_path):
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg is required for frame extraction verification")

    video = tmp_path / "source.mp4"
    subprocess.run(
        [
            "ffmpeg", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=64x48:rate=24", "-frames:v", "48",
            "-c:v", "mpeg4", str(video),
        ],
        check=True, capture_output=True, text=True)

    frames = extract_frames(str(video), str(tmp_path / "extracted"))
    assert len(frames) == 48


def test_output_verification_rejects_a_missing_frame(tmp_path):
    from PIL import Image

    for index in (0, 2):
        Image.new("RGBA", (8, 8), (0, 0, 0, 0)).save(
            tmp_path / f"frame_{index:04d}.png")

    with pytest.raises(RuntimeError, match="frame preservation check failed"):
        _verify_output_frame_sequence(str(tmp_path), expected_count=3)


def test_pipeline_never_replaces_a_frame_with_a_neighbor():
    source = Path("scripts/track_then_matte.py").read_text(encoding="utf-8")
    main_body = source[source.index("def main():"):]
    assert "repair_opacity_flashes(final_dir" not in main_body


def test_opt_in_real_pet_video_preserves_all_decoded_frames(tmp_path):
    """Run against a consented pet clip supplied by release verification."""
    configured_path = os.environ.get("REALPET_E2E_PET_VIDEO")
    if not configured_path:
        pytest.skip("set REALPET_E2E_PET_VIDEO to run the real-sample E2E check")
    video = Path(configured_path)
    if not video.is_file():
        pytest.fail(f"REALPET_E2E_PET_VIDEO does not exist: {video}")

    probe = subprocess.run(
        [
            "ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(video),
        ],
        check=True, capture_output=True, text=True)
    expected_count = int(probe.stdout.strip())
    extracted = extract_frames(str(video), str(tmp_path / "extracted"))

    assert expected_count > 0
    assert len(extracted) == expected_count
