# RealPet Target Architecture

## Product boundary

RealPet turns owner-imported pet photos or video into one desktop companion.
The runtime renders processed RGB/alpha frames rather than a generic breed
template. Its active action library is a closed 12-slot kit: one head-follow
video plus eleven independently generated click actions.

A single ordinary video cannot contain enough information to reconstruct an
arbitrary pet as an indistinguishable, fully poseable 3D animal. In
particular, it has no observations for occluded surfaces, actions that were
not filmed, or independent head/eye geometry. The product must therefore not
claim pixel-identical novel poses from one clip. It can make a defensible
fidelity promise for captured frames and can improve interaction fidelity as
the owner supplies short action clips.

## Requirements

### Functional

- Require a Google/Supabase session before mounting the console, and persist
  one local pet catalog per authenticated user.
- Upload one to four pet photos into the user's private cloud gallery; import
  videos locally and isolate one detected pet.
- Render the resulting alpha frames in a transparent, always-on-top macOS
  desktop window.
- Track the cursor by selecting a retained frame from the all-direction
  `gaze_orbit` sequence. The authenticated MiniMax Edge Function resolves all
  one to four cloud-gallery photos as references.
- On a click, play the next installed action video, then return to the current
  head-follow pose.
- Submit exactly one MiniMax task for each action slot and install it
  at `actions/<kind>/` only after processing and validation.
- Preserve the exact input/output frame count throughout generated-action
  processing and retain source frames locally.

### Non-functional

- Startup to first visible frame: under 500 ms for a prepared pet.
- Playback: 24 fps target, dropping frames rather than growing memory.
- Frame cache: bounded to 18 decoded frames and 64 MB.
- Import: the expensive detection/matting work is off the main thread and is
  cancellable.
- Privacy: original reference photos are stored in the authenticated user's
  private Supabase gallery and sent to the selected video provider only for
  generation. Video, alpha frames, and features remain on the Mac.
- Recovery: persisted in-flight work becomes retryable after restart.

## Runtime topology

```text
Owner photos (1-4) / custom video
    |
    +--> Google OAuth -> private Supabase gallery
                                  |
                                  +--> Edge Function: all original photos
                                       -> MiniMax H3 reference_image inputs
    |
    v
QC/detection -> track + matting -> normalized RGB/alpha action frames
                                      |
                                      +--> actions.json (12 fixed slots)
                                      |
                                      +--> pet-features.json (Vision anchors)
                                      |
                                      v
SwiftUI singleton -> PetLauncher -> FrameSequencePetRuntime -> transparent NSPanel
                                           |                         |
                                           v                         +--> cursor/tap observations
                                    InteractionHub <--- PetBehaviorDirector
```

The Python pipeline owns asset preparation only. The macOS app owns windows,
file drops, pointer observation, frame scheduling, and behavior dispatch.
There is no Python GUI process in the target runtime.

## Visual fidelity tiers

| Tier | Asset source | Behaviour quality | Product status |
| --- | --- | --- | --- |
| Head-follow | One MiniMax video conditioned on original owner photos | Retained frame-based cursor gaze | Required first action |
| Fixed action video | One quality-gated MiniMax video per named slot | Plays in full, then returns to head following | Opt-in per slot |
| Source loop | Matched RGB/alpha frame pairs from an imported video | Real captured movement | Video import baseline |
| Incomplete fixed kit | Head-follow plus any subset of 11 click actions | Only installed actions can play | Expected during setup |
| Generative/rigged model | A new image, rig, or inferred mesh | Novel pose only, visual identity can drift | Not a supported default |

## Data contracts

`PetStorage` persists one newest active `Pet` record, while preserving older
asset directories. `actions.json` is an allow-listed manifest rooted under the
prepared frame directory. Every fixed action owns exactly one `actions/<kind>/`
frame sequence. Runtime commands remain versioned and expiring; cursor and tap
handling never open, execute, or persist a dropped file.

## Rollout plan

1. Use the native source-frame renderer for every prepared action.
2. Require a 12-slot fixed action manifest and a one-to-one mapping from a
   selected slot to one MiniMax H3 task.
3. Preserve all generated frames through extraction, matting, validation, and
   installation; reject frame-count mismatches.
4. Measure identity and temporal quality on generated output before raising
   product claims beyond this implementation contract.

## Failure modes

| Failure | User impact | Handling |
| --- | --- | --- |
| No pet or multiple ambiguous pets | Wrong subject could be extracted | Stop import and require a better clip/selection flow |
| Matting quality fails | Visual artifacts | Reject the output before it is shown |
| Missing action slot | User clicks before that named video is installed | Skip unavailable slots and keep cursor head following |
| Provider task failure | The selected MiniMax action cannot be created or completed | Leave current action directories unchanged and show the provider error |
| Corrupt frame directory | Blank or unsafe runtime | Validate paths and fail launch with a retryable error |
| Slow storage/large clip | Stutter or memory pressure | Bounded decoded-frame cache and frame dropping |

## Removed default

The previous atlas/rig path was removed because it cannot preserve the owner's
pet: authored part layers and image generation can alter markings and
proportions. Source frames are the only supported desktop runtime.
