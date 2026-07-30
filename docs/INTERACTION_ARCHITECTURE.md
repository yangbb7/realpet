# RealPet Interaction Architecture

## Status

The desktop renderer is a native `NSPanel` that replays the owner’s alpha-matted
source frames. It is the default for every new import; a legacy Live2D/Cubism
package is optional and is never required to show a pet. The pipeline retains
the source clip and its extracted RGB/alpha pairs, then writes two local,
versioned manifests beside the frames:

- `actions.json`: idle plus any captured or generated action clips.
- `pet-features.json`: Vision-derived head, eye, nose, and front-paw anchors.

Pointer observation, personality decisions, semantic capability gates, local
camera/speech/VLM adapters, bounded ephemeral evidence, and session-only
behavior memory remain implemented. Raw camera frames, microphone audio, and
transcripts are not persisted by these adapters.

## Runtime Flow

```text
owner video -> clip selection -> pet detection -> SAM2 tracking + BiRefNet matting
                                             |
                                             v
                        RGB/alpha source frames + actions.json + pet-features.json
                                             |
pointer/camera/speech -> InteractionHub -> PetBehaviorPolicy -> PetCommand
                                             |
                                             v
                         FrameSequencePetRuntime (transparent native NSPanel)
```

The Swift app owns interaction state and runtime windows. Python owns offline
video analysis and matting only. No model output can directly access AppKit,
files, or processes.

## Interaction Contract

`InteractionObservation` is the only semantic input contract. It carries a
schema version, source, kind, timestamps, confidence, normalized coordinates,
and optional expiring evidence metadata, never raw media bytes. Every producer
uses `InteractionAdapter` and sends observations through `InteractionHub`.

The policy maps the requested desktop behaviors as follows:

| User input | Semantic event | Runtime action |
| --- | --- | --- |
| Cursor moves near pet | `pointer.near` | closest captured gaze loop |
| Primary click | `pet.tapped` | `lie_down` |
| File dropped over body | `user.pet.file_drop.body` | `paw` |
| File dropped over head | `user.pet.file_drop.head` | `eat` |

Head drops use Vision’s head region when available, with a documented upper-body
geometric fallback when a landmark is unavailable. The renderer only checks the
dragged pasteboard type and does not read, open, or execute the dropped file.

The runtime plays a matching captured sequence only. A missing sequence does
not trigger a local visual fallback: it leaves the source loop intact and emits
an unavailable-response result. Gaze uses the closest captured left, right, up,
or down loop; idle is the centre position. This keeps every fidelity-mode pixel
traceable to owner footage.

## Captured Response Acceptance

The response-material checklist covers four gaze clips and `lie_down`, `paw`,
and `eat`. A local video is processed by the normal tracker/matte pipeline,
then the action validator checks the requested motion and compares its matted
foreground hue/saturation distribution and normalized silhouette with the idle
frames. The comparison is a conservative wrong-pet/matte-breakage gate, not a
biometric identity claim. A passed candidate remains in staging until the owner
reviews its looping processed frames and explicitly installs it. Discarding a
candidate removes staging data only; it never replaces an accepted response.

## Generated Action Clips

Image-to-video is an optional asset-production path for actions not present in
the owner’s video. It is not the identity baseline. A request must use at least
one owner-approved reference image and, where the provider supports it, multiple
subject references or first/last frame constraints. The product generates the
target action directly (`lie_down`, `paw`, or `eat`); it does not synthesize a
generic turntable merely to sample arbitrary frames.

```text
approved reference frames + action prompt
       -> provider video job -> decode at fixed FPS -> track/matte
       -> identity + temporal + anatomy quality gate -> actions/<kind>/
       -> actions.json (origin: generated) -> user preview/accept
```

Acceptance requires all of the following:

1. Subject similarity against owner reference frames clears a calibrated
   threshold, including coat markings and face landmarks.
2. Consecutive frames clear temporal-stability and alpha-edge checks.
3. The action starts and ends in a compatible pose with the source idle loop.
4. The user previews and accepts the result. A rejected result is deleted or
   remains uninstalled; it cannot replace source idle frames.

`PetActionManifest.Action.origin` records `captured` or `generated`; absent
origins in older manifests are interpreted as `captured`. This makes the
provenance visible in the product and enables one-click return to owner footage.
Provider credentials, billing, retention policy, and generation consent belong
behind a server-side job API and must not ship in the macOS app.

## Capability And Safety Rules

Capabilities describe what a pet has real assets for: locomotion, reactions, and
orientation. Commands are schema-checked, pet-ID scoped, expiry-checked, and
capability-gated before the runtime receives them. Unknown action names and
out-of-bounds coordinates are rejected. Dragging and pausing suppress ordinary
autonomous commands but retain bounded semantic state.

The optional local behavior planner may advise only `none`, `react`, or
`wander`; deterministic Swift code remains authoritative. It receives no raw
frames, paths, runtime handles, or microphone content. Camera, speech, and local
VLM adapters similarly emit allow-listed semantics, apply backpressure, and
discard late or expired results.

## Legacy Cubism

`CubismWebPetRuntime` remains available solely to open existing compiled
packages. It is isolated from new imports and included in a bundle only when a
release maintainer explicitly sets `REALPET_INCLUDE_LEGACY_CUBISM=1` with the
licensed runtime files present. See `CUBISM_SETUP.md` for that migration-only
path.
