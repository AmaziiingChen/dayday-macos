# ADR 0100: Health archive core contract

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The iPhone Companion has a protected, implementation-private HealthKit queue. The Mac needs a
durable archive that can receive those facts without importing HealthKit, opening the iPhone
database, or joining the work-report and journal domains.

## Decision

`DaydayCore` owns a closed `HealthObservationKind` catalog, typed factual payload, source-scoped
HealthKit UUID key, observation tombstone, and idempotent `HealthArchiveBatch`. The batch is
validated before storage: all facts must originate from its opaque Companion installation ID, and
it cannot contain duplicate or mutually conflicting fact/tombstone keys.

`HealthArchiveRepository` exposes only atomic batch apply, bounded fact query, and factual
coverage. It has no HealthKit, Network, SwiftUI, AI, journal, work-report, or remote API dependency.

## Consequences

- A future LAN receiver maps its authenticated Companion transfer into this contract and can retry
  a known batch safely.
- The Mac archive keeps source provenance, time range, raw typed value/unit, and receipt time; it
  does not invent a health score, conclusion, diagnosis, or cross-domain relationship.
- Clinical records, documents, waveforms, routes, location traces, medication and lab data remain
  impossible to represent through this v1 contract.
