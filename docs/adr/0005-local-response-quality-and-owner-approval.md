# ADR-0005: Accept response footage only after local continuity checks and owner approval

## Status

Accepted

## Context

ADR-0004 requires every fidelity interaction to come from captured owner
footage. A manifest slot alone is not enough: an owner can select a clip of a
different pet, a severely broken matte, or a clip with no meaningful target
motion. Automatically accepting such a clip would make a response pack look
complete while weakening the product's visual claim.

## Decision

Keep the existing SAM2/BiRefNet processing quality gates as the alpha and
temporal authority. After that processing, validate the selected response
locally against three additional criteria:

1. The requested motion has observable action semantics. Gaze clips require
   head motion without substantial lower-body motion; the existing action
   checks remain responsible for the response clips.
2. The alpha-matted candidate's foreground hue/saturation distribution and
   normalized silhouette remain sufficiently similar to the imported pet's
   idle frames. This is a conservative continuity check, not a claim of
   biometric pet recognition.
3. A person must review the processed, looping response and explicitly install
   it. Dismissal or discard deletes only the staging work and leaves an already
   installed response untouched.

The workbench reports completion for four directional gaze clips plus
`lie_down`, `paw`, and `eat`. The idle loop is the centred gaze state.

## Consequences

- A response asset cannot become live merely because a video import completed.
- The product can reject an obvious wrong-pet capture without sending owner
  media off-device.
- The final perceptual decision remains with the owner, which is necessary
  because local histogram/silhouette metrics cannot prove identity under every
  lighting and pose variation.
- A source-loop companion remains usable when the pack is incomplete, while
  exact unavailable interactions continue to fail closed.
