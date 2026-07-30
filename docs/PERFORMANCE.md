# RealPet Performance Baseline

Measured on 2026-07-21 using an Apple M5 Mac with 32 GB RAM. These are
regression baselines for the memory-bounded pipeline and desktop renderer.

No optimization in this baseline changes model architecture, MPS inference
parameter values, input resolution, output resolution, frame rate, temporal
window, matte precision, or supported video formats.

## Results

| Benchmark | Before | After | Change |
|---|---:|---:|---:|
| Temporal smoothing, 48 x 720p, time | 1.891 s | 0.790 s | -58.2% |
| Temporal smoothing, maximum RSS | 750,043,136 B | 202,358,784 B | -73.0% |
| SAM2 tracking storage, 48 x 720p | 176,947,200 B | 44,236,800 B | -75.0% |
| SAM2 storage benchmark, maximum RSS | 216,760,320 B | 92,258,304 B | -57.4% |
| Cached desktop pet, 100 x 800px, maximum RSS | 382,418,944 B | 147,062,784 B | -61.5% |
| First cache preparation, 60 x 600px, maximum RSS | 314,048,512 B | 152,748,032 B | -51.4% |
| First cache preparation time | 0.050 s | 0.026 s | -48.0% |
| Swift executable in `.app` | 951,432 B | 448,784 B | -52.8% |
| BiRefNet checkpoint | 884,878,856 B | 444,473,596 B | -49.8% |
| BiRefNet load/inference maximum RSS | 1,506,459,648 B | 655,785,984 B | -56.5% |
| Full 16-frame model pipeline maximum RSS | 1,936,113,664 B | 1,023,311,872 B | -47.1% |

The lazy renderer takes approximately 0.52 ms to materialize an 800 x 800 RGBA
frame, comfortably below the 100 ms frame budget at the product's 10 FPS.

Temporal smoothing produced the same checksum before and after:

```text
5638464207
```

The real BiRefNet smoke test produced byte-identical final RGBA hashes before
and after direct-FP16 loading, streaming storage, and compact SAM2 masks:

```text
50010c36f3420958942342b752a8a367594d787872aa9d83642e03f9a34d6a26
c846227bbbf91df6871e2907fb5704f455278a6207b5808a2a0904030e1d88a1
93be9cae257488141d41e4153066b5fd57692f097468bb3c7f58ab7b084a083a
```

The release FP16 checkpoint and the official FP32 checkpoint loaded with
`dtype=torch.float16` produced the same complete 754-tensor state hash:

```text
32092dac2112690840969976efd6907f5148f223cbee0b73feb9ef38d73dd5c8
```

Their three-frame MPS alpha output also produced the same combined hash:

```text
eb7d4837414574169a6b149b099a263cf524d0102756580ed4829a35a8430084
```

The final release pipeline was also run end to end for 16 frames. Every saved
RGBA PNG was byte-identical to the FP32-package baseline.

## Package Baseline

The release stores the exact FP16 values already used by the supported MPS
inference path instead of retaining an unused FP32 copy:

| Artifact | Before | After | Change |
|---|---:|---:|---:|
| BiRefNet packaged weights | 867,004 KiB | 434,154 KiB | -49.9% |
| SAM2 checkpoint | 152,356 KiB | 152,356 KiB | unchanged |
| Faster R-CNN checkpoint | 171,116 KiB | 171,116 KiB | unchanged |
| Bundled FFmpeg | 80,242,432 B | 80,242,432 B | unchanged |
| Complete `.app` | 1,271,352 KiB | 838,465 KiB | -34.0% |
| LZFSE DMG | 1,164,340,579 B | 748,629,985 B | -35.7% |

The remaining model weights are the package-size floor under the zero-quality-
regression constraint. Replacing a model, dropping FFmpeg codecs, or downloading
weights after installation would change output quality, format support, offline
behavior, or first-run experience, so those approaches remain excluded.

## Model Selection Gate

Apple Vision was tested against the existing detector on 185 stratified images
from Oxford-IIIT Pet. It is much faster, but its lower recall would be a visible
import regression, so the release keeps Faster R-CNN:

| Detector | Detected | Recall | Median steady latency |
|---|---:|---:|---:|
| Apple Vision `VNRecognizeAnimalsRequest` | 168 / 185 | 90.8% | 4.4 ms |
| Faster R-CNN ResNet-50 FPN v2 | 185 / 185 | 100.0% | 1,191.4 ms |

EdgeTAM and BiRefNet Lite are not numerically equivalent to the current models.
They remain research candidates and are not enabled in the default path.

## Required Gates

Before release:

```bash
cd RealPet && swift build -c release
python -m pytest tests -v --timeout=60
ruff check scripts/ pipeline/ tests/ --select E,F,W --ignore E501
REALPET_WEIGHTS_DIR=/path/to/weights ./build_app.sh
./build_dmg.sh
codesign --verify --deep --strict dist/RealPet.app
```

`tests/test_memory_optimization.py` checks the new streaming algorithms against
the previous whole-clip implementation. `tests/test_display_cache.py` checks
the lazy cache byte-for-byte against the original RGBA resize output.
`tests/test_model_packaging.py` checks FP16 conversion, scalar tensor shapes,
and local-model resolution.
