#!/usr/bin/env python3
"""Validate that processed frames contain the requested action semantics."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.action_quality import validate_response_candidate  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames-dir", required=True)
    parser.add_argument("--reference-frames-dir", required=True)
    parser.add_argument(
        "--kind", required=True,
        choices=[
            "walk", "run", "react", "shake_head", "play", "lie_down", "paw", "eat",
            "gaze_left", "gaze_right", "gaze_up", "gaze_down",
        ])
    args = parser.parse_args()
    result = validate_response_candidate(
        args.frames_dir, args.kind, args.reference_frames_dir)
    print(json.dumps({"type": "action_validation", **result}, ensure_ascii=False))


if __name__ == "__main__":
    main()
