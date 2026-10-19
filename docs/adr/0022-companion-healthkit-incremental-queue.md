# ADR 0022: Companion-local HealthKit incremental queue

- **Status:** Proposed
- **Date:** 2026-08-01

## Context

ADR 0021 deliberately stopped before any HealthKit sample was read or retained. The next isolated
companion slice needs to establish whether Dayday can reliably read the initial non-clinical types,
resume after interruption, and retain a local source queue without changing the Mac product's
shared domain contracts.

## Decision

The iPhone companion may read and locally retain only four user-authorized sample kinds: sleep
analysis, step count, workouts, and body mass. For each kind it uses an `HKAnchoredObjectQuery` and
persists its anchor only after the corresponding local queue transaction has succeeded. Added or
updated samples become a small companion-private record with UUID, kind, timestamps, source label,
and the necessary typed values; deleted HealthKit UUIDs become local tombstones.

The queue is a private, versioned JSON file in Application Support with iOS file protection. It has
no network side effect and is not a Mac database schema, a `DaydayCore` public type, or a future
wire format. The app does not record HealthKit payloads in logs. A later contract ADR must replace
or map these private records before LAN synchronization begins.

## Alternatives considered

- **Advance the HealthKit anchor before queue storage:** rejected because a crash between the two
  operations permanently loses samples from later incremental reads.
- **Mirror every HealthKit metadata field:** rejected for this probe; it needlessly expands the
  privacy surface before the permanent data schema is accepted.
- **Wait for Mac persistence first:** rejected because real iPhone sample and deletion behavior is
  an independently useful risk-reduction step.

## Privacy impact

The queue contains health facts only on the user's iPhone, protected by the app container and iOS
file protection. It excludes clinical/document/file objects, does not use iCloud, and has no
network or third-party disclosure path. The user can remove the companion's local app data through
iOS; a type-level in-app deletion control arrives with the permanent shared repository.

## Migration impact

The file envelope has an explicit version but is private to the companion. It may be discarded or
migrated when the future accepted shared schema is introduced; no existing Dayday data migrates.

## Consequences

- The companion can be verified against real HealthKit data and HealthKit deletions before Mac/LAN
  design is finalized.
- Queue tests cover idempotent replacement and deletion tombstones. Real HealthKit authorization,
  historical range, background delivery, and device-source behavior remain physical-device checks.
