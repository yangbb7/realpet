#!/usr/bin/env python3
"""Create a playback-ready short sequence from processed action frames."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.action_prepare import prepare_reaction_sequence  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--kind", required=True,
        choices=["react", "shake_head", "play", "lie_down", "paw", "eat", "custom"])
    parser.add_argument("--fps", type=int, default=0)
    args = parser.parse_args()

    result = prepare_reaction_sequence(
        args.frames_dir, args.output_dir, fps=max(0, args.fps))
    print(json.dumps({"type": "action_prepared", **result}, ensure_ascii=False))


if __name__ == "__main__":
    main()
