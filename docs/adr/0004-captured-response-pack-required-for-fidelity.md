# ADR-0004: Require a captured response pack for fidelity interactions

## Status

Accepted

## Context

ADR-0001 established source-frame rendering as the identity baseline. ADR-0002
allowed bounded source-image transforms when a response clip was missing. That
fallback still distorts the owner's pet and cannot satisfy a product promise
that interactions should look like the same real animal. The source runtime
also lacked a contract for genuine mouse-gaze coverage.

## Decision

Treat `gaze_left`, `gaze_right`, `gaze_up`, `gaze_down`, `lie_down`, `paw`,
and `eat` as explicit response assets. The idle loop supplies the centre gaze.
The source-frame renderer selects a captured gaze loop from cursor direction
and plays a captured response action for click and file drop. It does not apply
a full-image gaze/action warp when an asset is absent; it reports the missing
coverage instead.

Generated video, Live2D and other inferred representations remain optional
experiments or legacy compatibility paths. They cannot satisfy this fidelity
contract unless independently benchmarked and product-approved later.

## Consequences

### Positive

- Every fidelity interaction is traceable to owner footage.
- The asset manifest now describes and tests mouse-gaze coverage explicitly.
- A missing clip cannot be mistaken for a successful but generic interaction.

### Negative

- Full interaction readiness requires several short owner recordings.
- A first idle-only import has intentionally limited behaviour.
- Switching among gaze loops needs capture guidance and transition validation.

## Alternatives considered

- **Keep bounded image transforms:** rejected because the output remains a
  distortion, not observed pet movement.
- **Generate missing clips on-device or in the cloud:** rejected as a default
  because identity and temporal consistency are not reliable enough.
- **Fit a 2D/3D rig from the idle video:** rejected because rig parameters and
  unseen poses are inferred rather than captured.
