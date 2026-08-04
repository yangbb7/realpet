# RealPet fidelity-first refactor plan

## Product contract

RealPet is a local macOS companion made from footage of one named pet. The
product must preserve that pet's observable coat pattern, proportions, face,
and captured movement. It must never silently replace an unavailable behaviour
with a generic breed, a generated animal, or a 2D deformation that is presented
as the owner's pet performing the action.

A single monocular video cannot observe an animal's occluded surfaces or prove
how it looks while performing a pose that is absent from the recording. The
deliverable promise is therefore:

1. Imported and response frames are the owner's original pixels after local
   tracking and matting.
2. Mouse gaze and the three required responses use a captured response clip
   when that clip has passed local validation.
3. Missing coverage is visible as a capture requirement, never hidden behind a
   synthetic fallback.

## Requirements and acceptance targets

| Area | Target |
| --- | --- |
| Identity | Idle and all fidelity-mode responses use alpha-matted owner footage only. |
| Pointer | Five captured gaze clips (left, right, up, down, centre/idle) select the closest direction within 100 ms; no full-image gaze warp. |
| Click | A captured `lie_down` clip plays once. |
| Body drop | A captured `paw` clip plays once; dropped files are neither opened nor persisted. |
| Head drop | A captured `eat` clip plays once; head hit-testing uses Vision landmarks with a geometry fallback. |
| Performance | Prepared pet reaches first frame in under 500 ms; target 24 fps; cache at most 24 decoded frames. |
| Privacy | Videos, frames and feature manifests remain under application support by default. |
| Recovery | Imports are cancellable, persisted work is retryable, and corrupt manifests fail closed. |

## Review findings

| Priority | Finding | Impact | Refactor response |
| --- | --- | --- |
| P0 | A source-frame runtime used global scale/rotation/translation fallbacks for gaze and missing actions. | It visibly changes the pet instead of replaying owner footage. | Remove visual fallbacks and select captured gaze/action sequences only. |
| P0 | Action capability was broad: any reaction asset could authorise a click/drop whose exact asset was missing. | The UI could imply a supported interaction before its actual footage existed. | Introduce explicit captured response slots and runtime rejection of an unavailable cue. |
| P1 | `actions.json` has no gaze coverage model. | The product cannot test or communicate whether mouse following is genuine. | Add five gaze action kinds and a fidelity-readiness query. |
| P1 | Live2D/Cubism and image-to-rig paths were costly legacy compatibility code. | Template fitting and generated rig parts cannot preserve a specific animal. | Removed from the application target; source frames are the only renderer. |
| P1 | Automated tests cover contracts but not a complete response-pack path. | Regressions can restore a synthetic fallback unnoticed. | Add manifest and action-capability tests, then add macOS runtime interaction checks. |
| P2 | One 10-fps clip is insufficient for all behavioural coverage. | Smoothness and motion variety are capture-limited. | Add a guided multi-clip capture flow and quality gates in phase 2. |

## Target architecture

```text
Owner capture pack (local videos)
  |-- idle / gaze-left / gaze-right / gaze-up / gaze-down
  |-- lie-down / paw / eat
  v
quality gate -> pet detection -> SAM 2 tracking -> BiRefNet matting
  v
versioned action manifest + Vision feature manifest
  v
Swift source-frame runtime (transparent NSPanel)
  |-- cursor vector -> closest captured gaze loop
  |-- click -> lie-down
  |-- body file drop -> paw
  `-- head file drop -> eat
```

The Python side prepares local assets only. Swift owns AppKit windows, input,
manifest containment checks, scheduling, and command dispatch. There is no
Python GUI and no model output may open a dropped file or drive AppKit.

## Technology decision

Use a modular local macOS application: Swift/AppKit for the desktop surface,
Python only for asynchronous video preparation, SAM 2 for promptable video
tracking, BiRefNet for alpha matting, and Apple Vision animal pose landmarks
for hit regions. This preserves the low operational cost of a single local
product while keeping the expensive pipeline out of the UI process.

Do not use Live2D, image-to-rig, a generic 3D mesh, or image-to-video as the
default renderer. They infer or redraw unobserved detail. 4D Gaussian Splatting
is a research-track option for a deliberate multi-camera/multi-view capture
mode, not a credible replacement for a one-video desktop product today.

Research references:

- Apple Vision supports animal body-pose observations and supported joints:
  <https://developer.apple.com/documentation/vision/vndetectanimalbodyposerequest>
- SAM 2 supplies promptable video segmentation and tracking:
  <https://github.com/facebookresearch/sam2>
- BiRefNet is the current matte implementation used by this repository:
  <https://github.com/ZhengPeng7/BiRefNet>
- 4D Gaussian Splatting is real-time dynamic-scene reconstruction research,
  but requires reconstruction assumptions beyond a casual monocular pet clip:
  <https://github.com/hustvl/4DGaussians>

## Migration phases

### Phase 1: fidelity contract and playback (delivered)

- Add gaze action slots to the manifest and importer.
- Remove source-frame image warps for gaze and missing reactions.
- Select an owner-captured gaze loop from the pointer vector.
- Play click/body-drop/head-drop only when the exact capture exists.
- Record the decision in an ADR and test manifest capability parsing.

### Phase 2: guided capture and validation (delivered)

- Build a guided import workbench for the four gaze directions and three
  interaction clips, with on-screen coverage progress. The product asks the
  owner to import existing local videos; it does not record or generate footage
  behind their back.
- Reuse the tracker/matte pipeline's alpha-quality and temporal-repair gates,
  then score action semantics and foreground appearance continuity against the
  idle reference before an owner preview can accept the asset.
- Show response-pack readiness in the library. An incomplete pack can still
  launch as an honest source-loop companion, but all unavailable fidelity
  interactions fail closed until their exact captured clip is accepted.

### Phase 3: release gate (requires physical release hardware)

- The bounded native frame cache, exact-cue rejection, action-library atomic
  install, Python quality fixtures, and Swift interaction contracts are in
  place.
- Before a public release, measure 24 fps p95 and first-frame latency on M1,
  M2, and M3 hardware using real captured packs; only then decide whether a
  Metal compositor is needed. A renderer rewrite without measurements is not a
  fidelity or performance improvement.
- Run signed/notarized app installation and real macOS pointer/file-drop tests
  on release hardware. These are release validation activities, not claims
  that can be completed from a source checkout.

### Phase 4: optional volumetric research

- Only after multi-view capture is available, benchmark a 4D representation
  against captured-frame identity, temporal stability, latency, asset size,
  battery impact and failure rate. It must beat the response-pack baseline
  before it can become a user-visible renderer.

## Failure handling

The runtime rejects expired commands, wrong-pet commands, out-of-root paths,
and absent response clips. A failed imported response leaves the previously
accepted action untouched. Missing gaze/action coverage remains a known,
actionable asset state rather than a visual approximation.
