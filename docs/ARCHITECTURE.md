# RealPet Target Architecture

## Product boundary

RealPet turns a locally imported pet video into a desktop companion. Its
primary visual contract is source fidelity: the default renderer presents
pixels extracted from the owner's footage, rather than redrawing the pet with
a template, a text-to-image model, or a generic breed model.

A single ordinary video cannot contain enough information to reconstruct an
arbitrary pet as an indistinguishable, fully poseable 3D animal. In
particular, it has no observations for occluded surfaces, actions that were
not filmed, or independent head/eye geometry. The product must therefore not
claim pixel-identical novel poses from one clip. It can make a defensible
fidelity promise for captured frames and can improve interaction fidelity as
the owner supplies short action clips.

## Requirements

### Functional

- Import a local pet video and isolate one detected pet.
- Render the resulting alpha frames in a transparent, always-on-top macOS
  desktop window.
- Track the cursor by selecting a captured `gaze_left`, `gaze_right`,
  `gaze_up`, or `gaze_down` source loop; the idle loop is the centre gaze.
- On a click, play a captured `lie_down` action.
- On a file drop over the body, play captured `paw`; on the head region, play
  captured `eat`.
- When a response asset is missing, preserve the idle source loop and expose
  the capture requirement; never deform the full pet image as a substitute.
- Keep all source video and derived assets in local application support
  storage. Do not require a cloud image-generation service to show a pet.

### Non-functional

- Startup to first visible frame: under 500 ms for a prepared pet.
- Playback: 24 fps target, dropping frames rather than growing memory.
- Frame cache: bounded to 24 decoded frames.
- Import: the expensive detection/matting work is off the main thread and is
  cancellable.
- Privacy: video, alpha frames, and features never leave the Mac in the
  default path.
- Recovery: persisted in-flight work becomes retryable after restart.

## Runtime topology

```text
Local video
    |
    v
QC -> pet detection -> track + matting -> normalized RGB/alpha frames
                                          |
                                          +--> actions.json (idle + captured response pack)
                                          |
                                          +--> pet-features.json (Vision head/eye/paw anchors)
                                          |
                                          v
SwiftUI library -> PetLauncher -> FrameSequencePetRuntime -> transparent NSPanel
                                      |                         |
                                      v                         +--> mouse/file-drop observations
                               InteractionHub <--- PetBehaviorDirector
```

The Python pipeline owns asset preparation only. The macOS app owns windows,
file drops, pointer observation, frame scheduling, and behavior dispatch.
There is no Python GUI process in the target runtime.

## Visual fidelity tiers

| Tier | Asset source | Behaviour quality | Product status |
| --- | --- | --- | --- |
| Source loop | Matched RGB/alpha frame pairs from the imported video | Real captured movement | Default |
| Captured response pack | Gaze plus separately captured, validated action clips of the same pet | Real gaze, lie-down, paw, and eating movement | Fidelity mode |
| Incomplete capture pack | Source loop only | Shows the real pet but declares missing response coverage | Default after one idle import |
| Generated action | Quality-gated image/video output derived from approved owner references | May add an experimental non-fidelity action, subject to identity drift risk | Never used by fidelity mode |
| Generative/rigged model | A new image, rig, or inferred mesh | Novel pose only, visual identity can drift | Not a supported default |

## Data contracts

`Pet` persists the source location, prepared frame directory, frame rate, and
the chosen renderer. `actions.json` is an allow-listed action manifest rooted
under the prepared frame directory. Runtime commands remain versioned and
expiring. File drops publish semantic observations; the renderer never opens,
executes, or persists a dropped file.

## Rollout plan

1. Make the native frame renderer the import default and retain Live2D only as
   a legacy fallback. This is implemented in the current refactor.
2. Add a guided action-capture flow for gaze directions plus short `lie_down`,
   `paw`, and `eat` clips, with automatic validation against the base pet
   identity. The implemented local workbench shows 7-slot coverage, reuses the
   matte pipeline's quality gates, compares foreground appearance to the idle
   frames, and requires owner preview/acceptance before atomic installation.
3. Extract animal-pose/landmark confidence to define head and eye regions. This
   is implemented with Vision and falls back to geometry when unavailable.
4. Integrate a server-side image/video action-generation service only after it
   meets measured identity similarity, temporal consistency, retention, billing,
   and explicit-consent requirements. Generated clips must be marked in the
   manifest and cannot replace the source loop.

## Failure modes

| Failure | User impact | Handling |
| --- | --- | --- |
| No pet or multiple ambiguous pets | Wrong subject could be extracted | Stop import and require a better clip/selection flow |
| Matting quality fails | Visual artifacts | Reject the output before it is shown |
| Missing response clip | Requested gaze or action is not captured | Keep source idle and request the corresponding capture; never substitute a generic animal |
| Corrupt frame directory | Blank or unsafe runtime | Validate paths and fail launch with a retryable error |
| Slow storage/large clip | Stutter or memory pressure | Bounded decoded-frame cache and frame dropping |

## Removed default

The previous default path generated an atlas from a reference frame and fitted
it to a Live2D Cubism template. That cannot preserve the owner's pet: Cubism
requires authored part layers, deformers, and motion data, while image
generation may alter markings and proportions. The code remains only to open
existing legacy assets; it is not part of a new import or normal launch path.
