# ADR 0021: Health facts iPhone companion foundation

- **Status:** Proposed
- **Date:** 2026-08-01

## Context

Dayday's later health-facts capability needs an iPhone-side reader because the macOS application
cannot read a HealthKit store. The current macOS v0.1 collection/report milestone must remain
unaffected. The user has chosen a local-only design: the iPhone reads authorized, non-clinical
HealthKit facts and a Mac becomes the long-term local archive. iCloud, CloudKit, third-party
sync services, clinical records, document-like health objects, cloud AI sending, API, and MCP are
out of scope.

## Decision

Create an isolated feature branch and an independent iOS companion project. Its first foundation
slice may own only:

- an iPhone SwiftUI shell;
- HealthKit availability and authorization-request UI for a small initial catalog (sleep, steps,
  workouts, body mass);
- a durable, metadata-only plan for a future local import/sync queue;
- visible state that honestly distinguishes unavailable, not-yet-requested, requested, and failed
  states.

The slice must not persist HealthKit samples, introduce shared health domain types, edit the macOS
SQLite schemas, generate a LAN protocol, run a Bonjour listener, or expose any network/API/MCP
surface. Health facts are never written to logs. Actual sample normalization, retained storage,
local pairing, encrypted LAN transfer, and a Mac repository need separate accepted ADRs and
vertical slices.

## Alternatives considered

- **Extend the macOS target first:** cannot access a HealthKit store and would entangle a future
  mobile concern with the v0.1 macOS milestone.
- **Implement complete LAN synchronization now:** prematurely fixes shared types and wire format
  before real-device HealthKit behavior and data semantics are verified.
- **Use iCloud/CloudKit as a relay:** rejected by the accepted local-only direction and HealthKit
  privacy constraints.

## Privacy impact

Positive: this slice requests only the displayed initial read types, has no sample persistence,
does not open network connections, and stores no health content in its metadata-only queue state.
The eventual product requires granular consent, local encrypted pairing, and type-level deletion.

## Migration impact

None. This ADR does not define a public `DaydayCore` type, storage schema, or wire protocol.
Those interfaces require separate ADRs before they are shared with the macOS codebase.

## Consequences

- The iPhone UI and real-device authorization behavior can be built and tested without delaying
  the macOS work-report vertical slice.
- A later integration must replace the foundation queue's metadata-only items with a versioned
  health-observation envelope and durable transfer protocol.
