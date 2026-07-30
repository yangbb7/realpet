# ADR 0003: Generated Action Clips Are Quality-Gated

## Context

The owner may not have filmed the pet lying down, pawing at an object, or
eating. Current image-to-video models can condition motion on a reference image
or, in some providers, multiple subject images and first/last frames. That makes
them useful to fill a missing action library, but they can alter coat markings,
facial proportions, limbs, or motion across frames.

## Decision

Source RGB/alpha frames remain the visual identity baseline. A generated video
is allowed only as an opt-in action candidate. The client sends a consented,
owner-approved reference package to a server-side job service, which asks for a
specific short action rather than a generic rotation. It samples the returned
clip at a fixed frame rate, tracks and mattes it, then requires identity,
anatomy, alpha-edge, temporal-stability, pose-join, and owner-preview checks.

Accepted clips are stored beneath `actions/<kind>/` and serialized as
`origin: generated` in `actions.json`. Rejection leaves source frames unchanged;
fidelity-mode runtime does not substitute a generated clip or a local image
transform for a missing captured response.

## Consequences

- The product can add missing interaction poses without pretending generated
  content is original footage.
- Provider secrets, billing, and retention settings stay off-device.
- The same action-import interface continues to accept an owner-captured clip.
- A provider outage or failed quality gate cannot make an existing pet unusable.
