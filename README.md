# RealPet / 真实桌宠

Turn photos of your real pet into a realistic desktop companion on macOS.

RealPet identifies the owner's pet across several photos, turns a natural-language
motion request into an image-grounded video prompt, and installs the generated
motion only after the same local quality and identity checks used for imported
footage. The source-frame renderer replays alpha-matted frames in a borderless,
always-on-top native window.

> **v0.2.0 — Double-click to use**
> - All model weights and ffmpeg are bundled inside the .app. **No first-launch downloads.**
> - First launch only creates a Python virtual environment (~2 minutes, one-time).
> - Download the DMG, drag to /Applications, launch.

## Features

- **Photos → Generated Pet Motion**: Import 1–6 owner photos; Agnes Image 2.0
  first creates a unified identity anchor, `gpt-5.6-sol` on the configured
  compatible relay creates a constrained Chinese video prompt, and Agnes Video
  V2.0 generates the motion
- **Prompt Review Before Generation**: The optimized prompt remains editable;
  generation is an explicit second action rather than an automatic upload
- **Generated Action Installation**: Video jobs are created, polled, downloaded,
  segmented, identity-validated, previewed, and only then added to the pet's
  action library as `AI 生成`
- **Video → Source-Faithful Pet**: Owners may still import original footage;
  clip selection, pet classification, tracking, alpha matting, landmark
  extraction, and display run automatically
- **AI-Powered Extraction**: SAM2 tracking + BiRefNet matting for high-quality alpha extraction
- **Smart Clip Selection**: Long videos are automatically analyzed for the best pet segments
- **Transparent Window**: Borderless, always-on-top, click-through window with real transparency
- **Drag & Drop**: Move your pet anywhere on the desktop
- **Persistent Pets**: Pet source, personality, feature anchors, and action metadata are saved between launches
- **Resident Daemon**: Python daemon keeps models loaded for fast processing
- **Personality & Interaction Core**: Versioned multimodal events, personality
  presets plus a six-axis custom editor, click and back-and-forth petting
  gestures, immediate affection feedback, decaying short-term mood memory,
  multi-action playback, and capability-gated behavior
- **Source-Frame Runtime**: A bounded native frame cache renders processed
  RGB/alpha pairs directly; no template, breed model, or cloud generation is
  needed to display a pet
- **Action Workbench**: Generate idle, gaze, lie-down, paw, and eat actions from
  the pet's photo identity. Original owner footage can still replace any action
  when recorded fidelity is preferred
- **Unified Multimodal Input**: Pointer, camera, local VLM, and speech sources
  share one expiring observation pipeline with bounded evidence and backpressure
- **Local Visual Interaction**: Optional Apple Vision processing detects when
  you appear, approach, or wave; camera frames remain in bounded memory
- **Local Voice Interaction**: Optional on-device speech recognition maps a
  small command vocabulary into the same personality and capability gates;
  microphone audio and transcripts are not persisted
- **Local VLM Interaction (experimental)**: Discover an installed Ollama vision
  model and let it recognize allow-listed interactions from ephemeral camera
  keyframes; models can be installed from the settings sheet with streamed
  progress and cancellation, while remote endpoints and arbitrary commands are rejected
- **Local Behavior Planning (experimental)**: An independently selected Ollama
  model may choose `react`, `wander`, or no action from personality, mood, and
  recent semantic memory; capability gates and offline rules remain authoritative

## Requirements

- macOS 14.0+ (Sonoma), Apple Silicon recommended
- ~3 GB free disk space (bundled model weights + extracted frames)
- **Python 3.10 or newer** — used to run the AI pipeline
- Internet connection on first launch for Python packages and when you choose
  to use the optional prompt/video generation service

### What you need to install first

The app bundles everything except a Python interpreter. On first launch, a setup
wizard creates the Python environment for you — but you must have **Python 3.10+**
installed. macOS ships with an older Python (3.9), which is **not** sufficient.

If you don't already have Python 3.10+, install it with [Homebrew](https://brew.sh)
(no `sudo` needed on Apple Silicon):

```bash
# If you don't have Homebrew yet, install it first:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Then install Python:
brew install python@3.12
```

The first-launch wizard also shows these exact commands if it can't find a suitable
Python, so you can copy-paste them at that point and click **Retry**.

> **⚠️ Windows is not supported.** The app uses Swift/AppKit/SwiftUI and Apple's Metal GPU framework (MPS). The Python pipeline could theoretically run on other platforms, but the desktop app requires macOS.

### Tested on

| Date | macOS | Chip | Memory | Notes |
|------|-------|------|--------|-------|
| 2026-06-28 | 14.3.1 | Apple M2 Pro | 16 GB | v0.2.1: first-launch install verified end-to-end (venv + pip + offline weight load, ~71s). GUI import-video flow not yet run on a clean machine. |
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

0. Make sure **Python 3.10+** is installed (see [What you need to install first](#what-you-need-to-install-first)). This is the only prerequisite.
1. Download `RealPet.dmg` from the [latest release](https://github.com/DolaAIMii/realpet/releases/latest).
2. Double-click the DMG and drag `RealPet.app` to `/Applications`.
3. Launch from `/Applications` (right-click → Open the first time — the app is ad-hoc signed). First run sets up Python (~2 minutes, one-time).

Click **导入宠物照片** and select 1–6 clear photos of the same pet. In the
**动作工作台**, write what the pet should do in natural language, such as
“让它慢慢转一圈”. Open the gear button once to configure two independent
services. `gpt-5.6-sol` retains its existing OpenAI-compatible relay Base URL
and relay key for Prompt optimization. Agnes uses the direct official endpoint
`https://apihub.agnes-ai.com/v1`, `agnes-image-2.0-flash`, and
`agnes-video-v2.0` with a separate Agnes key. Both keys are stored separately
in the macOS Keychain.

Click **优化 Prompt**. The selected owner photos are sent only to the configured
`gpt-5.6-sol` relay, which identifies the pet and produces an editable prompt
constrained to a pure white background, fixed camera, photographic realism, and
the same pet. After reviewing or editing it, click **生成动作**. Only then does
RealPet call Agnes Image 2.0 to make one public identity anchor, followed by
Agnes Video V2.0 with that anchor and the approved prompt. RealPet polls the
task by its `video_id`, downloads the result, runs the local quality and
identity checks, and asks for installation.

The initial generated action must be **待机**. Once it has been installed, use
the same workbench to generate mouse gaze, lying down, pawing, and eating
actions. **导入实拍视频** remains available for a full source-frame pet or to
replace any generated action with owner-recorded footage.

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
native source-frame runtime. Cubism is optional legacy compatibility only.

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

All model weights are bundled inside `RealPet.app`. No downloads are required on first launch.

| Model | Size | Source |
|-------|------|--------|
| SAM2 (`sam2.1_hiera_tiny.pt`) | ~156MB | [Meta](https://github.com/facebookresearch/sam2) |
| BiRefNet-matting | ~900MB | [ZhengPeng7](https://huggingface.co/ZhengPeng7/BiRefNet-matting) |
| Faster R-CNN | ~175MB | [PyTorch](https://pytorch.org/vision/stable/models.html) |

If you are building from source, `scripts/bundle_weights.py` downloads all three into the `weights/` directory.

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `REALPET_WEIGHTS_DIR` | `weights/` | Directory for model weights |
| `REALPET_VENV` | `.venv` (project root) | Python virtual environment path |
| `REALPET_PROJECT_ROOT` | auto-detected | Project root directory override |

The visual interaction settings accept only a local Ollama loopback address.
When enabled, the app discovers installed models with the `vision` capability;
camera evidence remains in bounded memory and is never written to disk by this
workflow.

The motion service is configured in the in-app action workbench, not through an
environment variable. Its two Base URLs must be HTTPS unless they are loopback
addresses. `gpt-5.6-sol` remains on its configured compatible relay for Prompt
optimization. Agnes is direct-only for the canonical reference
(`agnes-image-2.0-flash`) and video (`agnes-video-v2.0`), using a separate
credential.

## Building the App

```bash
./build_app.sh
# Output: dist/RealPet.app (ad-hoc signed)
```

## License

[MIT](LICENSE)

## Acknowledgments

- [SAM 2](https://github.com/facebookresearch/sam2) — Meta (Apache-2.0)
- [BiRefNet](https://github.com/ZhengPeng7/BiRefNet) — ZhengPeng7 (MIT)
- [PyTorch](https://github.com/pytorch/pytorch) — Meta (BSD-3)
