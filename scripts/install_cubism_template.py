#!/usr/bin/env python3
"""Install a generated rig package into a precompiled Cubism template."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.cubism_template import install_cubism_template  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rig-dir", required=True)
    parser.add_argument("--template-dir", required=True)
    args = parser.parse_args()
    try:
        manifest = install_cubism_template(args.rig_dir, args.template_dir)
        print(json.dumps({
            "type": "cubism_template_installed",
            "installed": True,
            "manifest": str(manifest),
        }))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "type": "cubism_template_installed",
            "installed": False,
            "message": str(error),
        }))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
