# ADR 0102: Health archive export and local deletion

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The Mac health archive is a user-owned local copy of factual, non-clinical Apple Health data.
Receiving data alone is insufficient: the owner must be able to inspect a selected period, export
their factual copy, and remove it without allowing a later LAN retry to silently restore it.

## Decision

`HealthArchiveRepository` adds two explicit actions:

- a bounded deletion request must name at least one health kind and a date range;
- an export reads all matching factual observations into a documented `dayday-health-archive/v1`
  snapshot, only after the Mac user chooses a save location.

Deletion affects only the Mac archive. It does not invoke HealthKit, delete an iPhone source
record, modify the Companion queue, or send a network command. For every removed record key, the
archive keeps a small local suppression key. A later incoming retry of that exact HealthKit UUID is
acknowledged for transport reliability but not made visible again.

## Consequences

- A user can safely clean an accidental or unwanted local copy without changing Apple Health.
- Export contains raw facts, source provenance, time range, receipt time, and typed payload only;
  it has no pairing secret, work/journal data, model input, score, diagnosis, or inference.
- New HealthKit samples use new UUIDs and may still arrive after a local historical cleanup. A
  future explicit "re-import" feature may offer a deliberate way to remove suppressions.
