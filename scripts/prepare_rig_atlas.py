#!/usr/bin/env python3
"""Prepare a generated pet atlas for the rig compiler."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.rig_assets import prepare_rig_atlas  # noqa: E402
from pipeline.cubism_template import (  # noqa: E402
    install_cubism_template,
    validate_cubism_template,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--atlas", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--template-dir")
    args = parser.parse_args()
    try:
        manifest = prepare_rig_atlas(args.atlas, args.output_dir)
        compiled = False
        if args.template_dir:
            manifest = install_cubism_template(args.output_dir, args.template_dir)
            compiled = True
        print(json.dumps({
            "type": "rig_assets_prepared",
            "prepared": True,
            "compiled": compiled,
            "profile": (
                validate_cubism_template(args.template_dir)["profile"]
                if args.template_dir else None
            ),
            "manifest": str(manifest),
        }))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "type": "rig_assets_prepared",
            "prepared": False,
            "message": str(error),
        }))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
