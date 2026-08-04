# RealPet / 真实桌宠

Turn photos of your real pet into a realistic desktop companion on macOS.

RealPet turns an owner's pet video into a source-faithful desktop companion. It
can also create a fixed twelve-slot action kit from the pet's identity. Its
MiniMax H3 prompts are built in,
visible for debugging, and not editable. Generated motion is installed only
after the same local quality and identity checks used for imported footage. The
source-frame renderer replays alpha-matted frames in a borderless, always-on-top
native window.

> **v0.2.0 — Double-click to use**
> - All model weights and ffmpeg are bundled inside the .app. **No model download is needed on first use.**
> - The first media-processing operation creates a Python virtual environment (~2 minutes, one-time).
> - Download the DMG, drag to /Applications, launch.

## Features

- **Video → Source-Faithful Pet**: Import original pet footage; clip selection,
  pet classification, tracking, alpha matting, landmark extraction, and display
  run automatically
- **Fixed MiniMax Actions**: One MiniMax H3 request creates each selected
  head-follow or tap-action slot. Prompts are read-only and visible in the app
  for debugging
- **Generated Action Installation**: Video jobs are created, polled, downloaded,
  segmented, identity-validated, previewed, and only then added to the pet's
  action library as `AI 生成`
- **AI-Powered Extraction**: SAM2 tracking + BiRefNet matting for high-quality alpha extraction
- **Smart Clip Selection**: Long videos are automatically analyzed for the best pet segments
- **Transparent Window**: Borderless, always-on-top, click-through window with real transparency
- **Drag & Drop**: Move your pet anywhere on the desktop
- **Persistent Pets**: Pet source, feature anchors, desktop position, scale, and action metadata are saved between launches
- **On-Demand Detector**: Python starts for import work and releases model
  memory after two idle minutes
- **Deterministic Interaction Core**: Versioned multimodal events map fixed
  pointer, click, and file-drop inputs to installed action slots without
  autonomous movement or per-pet personality tuning
- **Source-Frame Runtime**: A bounded native frame cache renders processed
  RGB/alpha pairs directly; no template, breed model, or cloud generation is
  needed to display a pet
- **Fixed Action Surface**: The twelve built-in actions use fixed, inspectable
  prompts rather than user-written motion prompts. Separately, owners can
  import a named real-world video as a custom action after identity validation
- **Direct Desktop Input**: Pointer movement, clicks, petting, and file drops
  map deterministically to the installed action slots

## Requirements

- macOS 14.0+ (Sonoma), Apple Silicon recommended
- ~3 GB free disk space (bundled model weights + extracted frames)
- **Python 3.10–3.12** — used to run the AI pipeline
- Internet connection during the one-time Python setup and when you generate
  a cloud video action

### What you need to install first

The app bundles everything except a Python interpreter. When you first import
or generate media, a setup wizard creates the Python environment for you — but
you must have **Python 3.10–3.12**
installed. macOS ships with an older Python (3.9), which is **not** sufficient.

If you don't already have Python 3.10+, install it with [Homebrew](https://brew.sh)
(no `sudo` needed on Apple Silicon):

```bash
# If you don't have Homebrew yet, install it first:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Then install Python:
brew install python@3.12
```

The setup wizard also shows these exact commands if it can't find a suitable
Python, so you can copy-paste them at that point and click **Retry**.

> **⚠️ Windows is not supported.** The app uses Swift/AppKit/SwiftUI and Apple's Metal GPU framework (MPS). The Python pipeline could theoretically run on other platforms, but the desktop app requires macOS.

### Tested on

| Date | macOS | Chip | Memory | Notes |
|------|-------|------|--------|-------|
| 2026-06-28 | 14.3.1 | Apple M2 Pro | 16 GB | v0.2.1: first media-processing setup verified end-to-end (venv + pip + offline weight load, ~71s). GUI import-video flow not yet run on a clean machine. |
| 2026-06-27 | 14.3.1 | Apple M2 Pro | 16 GB | Agent-verified on maintainer's machine; not a clean-machine fresh-clone. See `docs/RELEASE.md` for the reproducibility protocol. |

> **v0.2.0 was broken** — the `.app` did not bundle the Python pipeline source or `requirements.txt`, so first launch could not complete. Fixed in v0.2.1. Do not use the v0.2.0 DMG.

### Performance Recommendations

RealPet runs real-time AI models (SAM2 tracking + BiRefNet matting + Faster R-CNN detection) on every frame. Performance matters.

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| **Chip** | Apple M1 | Apple M1 Pro or better | MPS (Metal) GPU acceleration is critical. Intel Macs work but are **significantly slower** (CPU-only inference ~5-10× slower). |
| **Memory** | 8GB | 16GB+ | SAM2 + BiRefNet + Faster R-CNN models together use ~3-4GB. With the OS and app, 8GB gets tight. 16GB gives comfortable headroom. |
| **Disk** | 3GB free | 5GB+ free | Model weights: SAM2 ~156MB, BiRefNet ~900MB, Faster R-CNN ~175MB. Plus space for extracted frames and output. |
| **GPU** | Apple M1 integrated | Apple M1 Pro/Max/Ultra or M2/M3/M4 | More GPU cores = faster inference. M1 base (~8 GPU cores) processes ~1 frame/2s. M1 Pro+ (~16 cores) processes ~1 frame/1s. |

**Processing time estimates (10-second video):**

| Chip | QC Gate | Pet Detection | Full Pipeline |
|------|---------|---------------|---------------|
| M1 (8 GPU) | ~4s | ~3s | ~60-90s |
| M1 Pro (16 GPU) | ~2s | ~1.5s | ~30-45s |
| M2 Pro/M3 Pro | ~1.5s | ~1s | ~20-35s |

**If processing feels slow:**
- Use shorter videos (5-15 seconds is ideal)
- Close other GPU-intensive apps (Final Cut, games, etc.)
- Ensure you're on Apple Silicon (Intel Macs will be very slow)
- The app shows progress — SAM2 tracking is the longest step

## Quick Start

0. Make sure **Python 3.10–3.12** is installed (see [What you need to install first](#what-you-need-to-install-first)). This is the only prerequisite.
1. Download `RealPet.dmg` from the [latest release](https://github.com/DolaAIMii/realpet/releases/latest).
2. Double-click the DMG and drag `RealPet.app` to `/Applications`.
3. Launch from `/Applications` (right-click → Open the first time — the app is ad-hoc signed), then sign in with Google. The console opens immediately; the one-time Python setup starts only when you first import or generate media.

Use **图片管理** to add one to four clear photos of the same pet. Select an
action slot from the pet control panel to generate its independent video;
custom actions can also be created from an imported real-world video. Built-in
prompts are displayed for inspection and are not editable.

Each built-in prompt follows MiniMax's image-to-video structure: identify the
first-frame subject, describe an ordered motion, keep the camera fixed, then
state the photographic visual direction. See the [official MiniMax video prompt
guide](https://platform.minimaxi.com/docs/guides/video-prompt).

Google login is required on every launch, and **图片管理** stores one to four
original photos in the signed-in owner's private Supabase gallery. MiniMax H3
is invoked only through an authenticated Supabase Edge Function, which resolves
all gallery photos as `reference_image` inputs and owns the MiniMax credential.
Generation never uploads or deletes reference photos; videos, extracted frames,
and actions remain local to the same Google account. The desktop client never
receives a Supabase `service_role` key or MiniMax API key.

Each selected slot creates exactly one provider task. RealPet polls the returned
task, downloads the result, runs local quality and identity checks, and installs
the complete frame sequence before the clip becomes available to the desktop
runtime.

For developers who prefer to build from source, see `docs/RELEASE.md`.

## Architecture

```
┌─────────────────────────────────────────────┐
│  macOS App (Swift/SwiftUI)                  │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ ControlPanel │  │ FrameSequence NSPanel │ │
│  └──────┬──────┘  └──────────┬───────────┘  │
│         │                    │              │
│  ┌──────┴────────────────────┴───────────┐  │
│  │ InteractionHub / Native Frame Runtime │  │
│  └──────┬────────────────────────────────┘  │
└─────────┼───────────────────────────────────┘
          │
┌─────────┴───────────────────────────────────┐
│  Python Pipeline                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Faster   │  │   SAM2   │  │ BiRefNet │  │
│  │ R-CNN    │→ │ Tracking │→ │ Matting  │  │
│  │ (detect) │  │ (track)  │  │ (alpha)  │  │
│  └──────────┘  └──────────┘  └──────────┘  │
└─────────────────────────────────────────────┘
```

**Pipeline**: `analyze_clips` → `detect_pet` → `track_then_matte` (SAM2 +
BiRefNet) → RGB/alpha frame pairs + `pet-features.json` + `actions.json` →
native source-frame runtime.

Runtime interaction uses versioned semantic observations rather than binding
behavior directly to mouse events. The same contract is designed for future
camera, speech, and VLM adapters. See
[`docs/INTERACTION_ARCHITECTURE.md`](docs/INTERACTION_ARCHITECTURE.md).

## Project Structure

```
realpet/
├── RealPet/              # Swift macOS app
│   ├── DeskPetApp.swift  # App entry (file name kept for SwiftPM target)
│   ├── Models/           # Pet model
│   ├── Services/         # PetLauncher, PetStorage, PythonBridge, PythonDaemon
│   ├── ViewModels/       # PetListViewModel
│   ├── Views/            # MainPanelView, PetRowView
│   └── Package.swift
├── pipeline/             # Python AI pipeline
│   ├── pet_detector.py   # Faster R-CNN pet detection
│   ├── action_quality.py # Captured-response validation
│   └── smart_clip.py     # Long-video clip selection
├── scripts/              # CLI tools
│   ├── track_then_matte.py  # Main pipeline (SAM2 + BiRefNet)
│   ├── detect_pet.py     # Pet detection
│   ├── quality_check.py  # QC gate
│   ├── analyze_clips.py  # Clip selection for long videos
│   ├── daemon.py         # Resident Python worker
│   └── download_weights.py # Weight downloader
├── tests/                # Unit tests (pytest)
├── weights/              # Model weights (git-ignored, downloaded)
├── requirements.txt      # Python dependencies
├── install.sh            # One-click installer
├── build_app.sh          # .app builder
├── LICENSE               # MIT
└── NOTICE                # Third-party licenses
```

## Model Weights

All model weights are bundled inside `RealPet.app`. No model download is required on first use.

| Model | Size | Source |
|-------|------|--------|
| SAM2 (`sam2.1_hiera_tiny.pt`) | ~156MB | [Meta](https://github.com/facebookresearch/sam2) |
| BiRefNet FP16 | ~450MB | Converted from [ZhengPeng7](https://huggingface.co/ZhengPeng7/BiRefNet-matting) |
| Faster R-CNN | ~175MB | [PyTorch](https://pytorch.org/vision/stable/models.html) |

For source releases, `scripts/bundle_weights.py` fetches the pinned SAM2 file,
the pinned BiRefNet commit, and the pinned Faster R-CNN file, then rejects any
SHA-256 mismatch before packaging.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `REALPET_WEIGHTS_DIR` | `weights/` | Directory for model weights |
| `REALPET_HF_CACHE_DIR` | `~/Library/Application Support/RealPet/huggingface` | Development download cache; never bundled |
| `REALPET_VENV` | `.venv` (project root) | Python virtual environment path |
| `REALPET_PROJECT_ROOT` | auto-detected | Project root directory override |

MiniMax H3 receives one to four cloud-gallery pet images through the
authenticated Supabase Edge Function. Release automation supplies the product's
public Supabase key through `REALPET_SUPABASE_PUBLISHABLE_KEY`; provider
credentials are server-only. Release builds also require verified `ffmpeg` and
`ffprobe` paths plus their matching SHA-256 values; the build script no longer
downloads an unpinned "latest" binary.

Python packages are installed from `requirements.txt`, which delegates to the
hash-locked `requirements.lock`. Regenerate both runtime and CI locks only with
Python 3.10 and `pip-compile --generate-hashes` after intentionally changing
`requirements.in` or `requirements-dev.in`.

## Building the App

```bash
./install.sh
REALPET_SUPABASE_PUBLISHABLE_KEY=<publishable-key> \
REALPET_FFMPEG_PATH=/path/to/verified/ffmpeg \
REALPET_FFMPEG_SHA256=<sha256> \
REALPET_FFPROBE_PATH=/path/to/verified/ffprobe \
REALPET_FFPROBE_SHA256=<sha256> \
REALPET_BUILD_PYTHON=.venv/bin/python \
./build_app.sh
# Output: dist/RealPet.app (ad-hoc signed)
```

## License

[MIT](LICENSE)

## Acknowledgments

- [SAM 2](https://github.com/facebookresearch/sam2) — Meta (Apache-2.0)
- [BiRefNet](https://github.com/ZhengPeng7/BiRefNet) — ZhengPeng7 (MIT)
- [PyTorch](https://github.com/pytorch/pytorch) — Meta (BSD-3)
