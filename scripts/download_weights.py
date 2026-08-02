#!/usr/bin/env python3
"""Unified weight downloader for realpet.

Downloads the SAM2 checkpoint to the project's weights/ directory.
BiRefNet and Faster R-CNN are auto-downloaded by their respective libraries
(HuggingFace from_pretrained and torchvision), so only SAM2 needs manual fetch.

Usage:
    python scripts/download_weights.py           # download all
    python scripts/download_weights.py --check   # only verify, don't download
"""
import argparse
import hashlib
import os
import sys
import urllib.request

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Configurable via REALPET_WEIGHTS_DIR env var
WEIGHTS_DIR = os.environ.get(
    "REALPET_WEIGHTS_DIR", os.path.join(PROJECT_ROOT, "weights"))

SAM2_URL = (
    "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt"
)
SAM2_SUBDIR = "sam2"
SAM2_FILENAME = "sam2.1_hiera_tiny.pt"
SAM2_EXPECTED_SIZE = 156_000_000
SAM2_SHA256 = "7402e0d864fa82708a20fbd15bc84245c2f26dff0eb43a4b5b93452deb34be69"


def _sam2_path():
    return os.path.join(WEIGHTS_DIR, SAM2_SUBDIR, SAM2_FILENAME)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sam2_is_verified(path):
    return (os.path.isfile(path)
            and os.path.getsize(path) >= SAM2_EXPECTED_SIZE * 0.9
            and sha256_file(path) == SAM2_SHA256)


def download_sam2(force=False):
    """Download SAM2 checkpoint. Returns True if already present or downloaded."""
    dest = _sam2_path()
    if os.path.exists(dest) and not force:
        if sam2_is_verified(dest):
            size = os.path.getsize(dest)
            print(f"SAM2 checkpoint verified: {dest} ({size:,} bytes)")
            return True
        print("Existing SAM2 checkpoint does not match the pinned SHA-256, "
              "re-downloading...")

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"Downloading SAM2 checkpoint to {dest} ...")
    print(f"  URL: {SAM2_URL}")

    try:
        def _progress(block_num, block_size, total_size):
            downloaded = block_num * block_size
            if total_size > 0:
                pct = min(100, downloaded * 100 // total_size)
                mb = downloaded / (1024 * 1024)
                total_mb = total_size / (1024 * 1024)
                print(f"\r  {pct}% ({mb:.1f}/{total_mb:.1f} MB)", end="", flush=True)

        urllib.request.urlretrieve(SAM2_URL, dest, reporthook=_progress)
        print()
        size = os.path.getsize(dest)
        if not sam2_is_verified(dest):
            os.remove(dest)
            print("Downloaded SAM2 checkpoint does not match the pinned SHA-256")
            return False
        print(f"Done. ({size:,} bytes)")
        return True
    except Exception as e:
        print(f"\nDownload failed: {e}")
        err_str = str(e)
        if "CERTIFICATE_VERIFY_FAILED" in err_str or "certificate verify failed" in err_str.lower():
            print()
            print("This usually means your Python install has no CA certificate store.")
            print("Try one of these (in order):")
            print("  1. Install Xcode Command Line Tools: xcode-select --install")
            print("     then run:")
            print("       /Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python.framework/Versions/Current/Install\\ Certificates.command")
            print("  2. Or download manually:")
            print(f"       {SAM2_URL}")
            print(f"       and place it at: {dest}")
        else:
            print("You can manually download from:")
            print(f"  {SAM2_URL}")
            print(f"  and place it at: {dest}")
        if os.path.exists(dest):
            os.remove(dest)
        return False


def check_all():
    """Check which weights are present. Returns list of missing items."""
    missing = []

    # SAM2
    sam2 = _sam2_path()
    if not os.path.exists(sam2):
        missing.append(f"SAM2 checkpoint: {sam2}")
    else:
        if sam2_is_verified(sam2):
            size = os.path.getsize(sam2)
            print(f"✓ SAM2 checkpoint: {sam2} ({size:,} bytes, SHA-256 verified)")
        else:
            missing.append(f"SAM2 checkpoint digest: {sam2}")

    # BiRefNet (auto-downloaded by HuggingFace)
    print("✓ BiRefNet-matting: auto-downloaded by HuggingFace from_pretrained()")
    print("  (first run requires internet; cached at ~/.cache/huggingface/)")

    # Faster R-CNN (auto-downloaded by torchvision)
    print("✓ Faster R-CNN: auto-downloaded by torchvision on first use")
    print("  (cached at ~/.cache/torch/hub/)")

    return missing


def main():
    parser = argparse.ArgumentParser(
        description="Download model weights for realpet")
    parser.add_argument("--check", action="store_true",
                        help="Only check which weights exist, don't download")
    parser.add_argument("--force", action="store_true",
                        help="Force re-download even if file exists")
    args = parser.parse_args()

    if args.check:
        missing = check_all()
        if missing:
            print(f"\nMissing: {', '.join(missing)}")
            sys.exit(1)
        else:
            print("\nAll weights present.")
        return

    # Download SAM2
    if not download_sam2(force=args.force):
        sys.exit(1)

    print()
    check_all()


if __name__ == "__main__":
    main()
