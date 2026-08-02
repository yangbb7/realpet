#!/usr/bin/env python3
"""Validate that processed frames contain the requested action semantics."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.action_quality import validate_response_candidate  # noqa: E402


# Keep this in sync with PetActionManifest.Action.Kind.fixedActionKinds.
# Legacy and custom values stay accepted so existing action packs can still be
# revalidated without being blocked by the fixed-action catalog migration.
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
LEGACY_ACTION_KINDS = (
    "walk",
    "run",
    "react",
    "shake_head",
    "play",
    "gaze_left",
    "gaze_right",
    "gaze_up",
    "gaze_down",
    "custom",
)
VALID_ACTION_KINDS = FIXED_ACTION_KINDS + LEGACY_ACTION_KINDS


def _json_default(value):
    """Convert NumPy scalars and arrays returned by quality metrics to JSON."""
    if hasattr(value, "tolist"):
        return value.tolist()
    if hasattr(value, "item"):
        return value.item()
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames-dir", required=True)
    parser.add_argument("--reference-frames-dir", required=True)
    parser.add_argument(
        "--kind", required=True,
        choices=VALID_ACTION_KINDS)
    args = parser.parse_args()
    result = validate_response_candidate(
        args.frames_dir, args.kind, args.reference_frames_dir)
    print(json.dumps(
        {"type": "action_validation", **result},
        ensure_ascii=False,
        default=_json_default,
    ))


if __name__ == "__main__":
    main()
