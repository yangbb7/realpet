# ADR-0001: Use source-frame rendering as the default desktop runtime

## Status

Accepted

## Context

The product's main promise is that a desktop pet visually matches the pet in
the owner's imported video. The existing default pipeline converted a selected
frame into a generated atlas and placed it on a precompiled Live2D template.
That process cannot retain a pet's exact coat, markings, anatomy, or captured
motion, and it requires proprietary runtime resources plus authored rigs.

## Decision

Use normalized RGB/alpha frames produced from the imported video as the
runtime asset. Present them in an AppKit transparent panel with a bounded
decoded-frame cache. Cubism is not part of the application target.

## Consequences

### Positive

- The default visible pet is made from the owner's pixels.
- New imports do not depend on an API key, cloud image service, or rig SDK.
- The rendering, pointer, and drop paths remain fully local.

### Negative

- A flat source sequence cannot make an unfilmed pose truthfully.
- Action coverage improves only when the owner supplies corresponding clips.
- This runtime needs explicit cache and timer discipline for smooth playback.

## Alternatives considered

- **Live2D as default:** rejected because it needs manual rig authoring and
  template fitting changes the animal's identity.
- **Generated image/video as default:** rejected because identity preservation
  is not reliable enough for the stated product promise.
- **Full 3D reconstruction from one clip:** deferred; a single clip lacks the
  necessary multi-view geometry and action observations.
