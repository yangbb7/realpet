# ADR-0002: Prefer captured interaction actions over synthetic animation

## Status

Superseded by ADR-0004

## Context

Click, body file-drop, and head file-drop require distinct pet behaviour. An
idle video cannot prove how a particular pet lies down, paws, or eats. Generic
or generated animation would make the pet look less like the owner's animal.

## Decision

Define explicit `lie_down`, `paw`, and `eat` action slots in the local action
manifest. When a validated source clip exists, play it. When it does not, use
a bounded source-preserving transform that communicates the interaction but
does not claim to be a real captured action.

## Consequences

### Positive

- The product has a clear path from a useful first import to high-fidelity
  interaction.
- Fallbacks never create a generic replacement animal.
- Action availability is observable and testable in one manifest.

### Negative

- Perfect action fidelity needs extra owner footage.
- The fallback is intentionally less expressive than a bespoke animation.

## Alternatives considered

- **Always synthesize the action:** rejected because it violates the visual
  identity constraint.
- **Reject all interactions without action clips:** rejected because it makes
  the first-import experience unnecessarily inert.
