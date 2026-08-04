# ADR-0006: One Global Pet and One Video Per Fixed Action

## Status

Accepted

## Context

The previous action workbench modeled a selectable scenario that could submit
multiple generated videos. It also retained a multi-pet list from an earlier
library product. Both models make cost, identity, playback, and recovery hard
to reason about: a user cannot tell which provider task owns which action, and
two desktop pets can compete for pointer interaction.

## Decision

The product persists and launches exactly one active pet. Importing photos or a
video replaces the active record and terminates a prior desktop runtime; prior
media directories are retained and never deleted as part of replacement.

The action catalog is closed to twelve slots:

1. `gaze_orbit` for head following.
2. Eleven tap-played actions: `lie_down`, `paw`, `eat`, `cry`, `angry_stomp`,
   `roll`, `stretch`, `sleep_snore`, `wave`, `jump_cheer`, and `cuddle`.

Each request selects one slot and submits exactly one MiniMax task through the
authenticated Supabase Edge Function. The Function resolves all one to four
original owner photos as `reference_image` inputs. The result is processed,
validated, and atomically installed at
`actions/<slot>/`; no scenario fan-out or install queue exists. The source and
installed frame counts must match, and neither processing nor installation may
sample or discard a frame.

Head following is the only action required before the other fixed slots. Its
prompt directs a fixed camera and stationary body with head and eyes moving;
the provider input contains only the owner-uploaded original photos. Every
remaining action requires the installed head-follow base and submits one
independent provider task using the same original-photo rules.

At runtime, cursor position selects a retained frame from the installed
head-follow sequence. A pet click advances to the next installed tap-action
video. When that sequence reaches its end, runtime immediately reads the
current pointer and resumes head following.

## Consequences

- Billing maps one-to-one from a selected action to a MiniMax task.
- Action files are independently replaceable and have an auditable origin.
- The desktop has one active interaction target and one transparent pet panel.
- Existing multi-pet records migrate to the newest record. Existing asset
  folders and legacy manifests remain readable but cannot add new legacy
  action slots.
- Generated output is still subject to visual identity and temporal quality
  limits; the implementation does not claim that a model can prove perfect
  visual equivalence for an unseen pose.
