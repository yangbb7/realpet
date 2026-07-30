#!/usr/bin/env python3
"""Validate a RealPet quadruped Cubism template without installing it."""

import argparse
import json
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJECT_ROOT)

from pipeline.cubism_template import validate_cubism_template  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template-dir", required=True)
    args = parser.parse_args()
    try:
        template = validate_cubism_template(args.template_dir)
        print(json.dumps({
            "type": "cubism_template_validated",
            "valid": True,
            "template": template["id"],
            "contract": template["contract"],
            "profile": template["profile"],
            "provenance": template["provenance"],
        }))
    except (OSError, ValueError) as error:
        print(json.dumps({
            "type": "cubism_template_validated",
            "valid": False,
            "message": str(error),
        }))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
