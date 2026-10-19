# ADR 0041: Broad, closed non-clinical HealthKit catalog for the iPhone companion

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The user has verified that their complete Apple Health export can be read locally on their Mac.
The Companion's earlier real-device probe retained only sleep analysis, steps, workouts, and body
mass. That sample catalog is no longer sufficient for the accepted product direction: Dayday is a
local factual archive and must be able to retain a broad set of Apple Health observations without
making health interpretations.

## Decision

The Companion reads a closed, reviewable set of non-clinical HealthKit sample types: cardiac and
respiratory observations, blood oxygen, sleep wrist-temperature change, activity and workouts,
body measurements, sleep and mindfulness sessions, mobility and running metrics, user-recorded
nutrition and hydration, and environmental or headphone audio exposure. Each type has an explicit
HealthKit identifier and a canonical unit before it can enter the companion-private queue.

The authorization request is broad but still granular at the Apple Health permission screen. A
missing authorization or absent device data remains an empty result; it is never represented as a
zero, a diagnosis, a score, or an inferred state. The Companion continues to be read-only and
local-only.

Clinical records, ECG and other waveform/file objects, audiograms, vision prescriptions, workout
routes and location traces, medications, lab or document-like objects remain outside this catalog.
The catalog is not an implicit promise to support all future Apple Health API types: a new type
requires an explicit addition with its storage semantics and privacy classification.

## Alternatives considered

- **Keep the four-type probe:** rejected because it cannot validate the actual personal archive
  scope.
- **Enumerate every object dynamically:** rejected because it obscures consent, unit semantics,
  availability, and high-risk exclusions.
- **Normalize or calculate health scores during import:** rejected; Dayday retains objective facts
  only.

## Privacy impact

The local queue expands to contain more sensitive but user-authorized facts. It remains protected
inside the iPhone app container, has no network side effect, no iCloud use, no logs, no clinical
content, and no AI disclosure path. The Mac transfer and durable shared schema still require a
separate decision.

## Migration impact

The private JSON queue's record shape already represents quantities with units, categories, and
workouts, so no on-device file migration is needed. Newly authorized types begin with a fresh
anchored query; existing anchors and observations remain intact.
