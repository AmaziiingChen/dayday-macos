# ADR 0004: Collector state and objective event envelope

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday has several independently consented collectors. Permission denial, later revocation,
user pause, lock, sleep, partial operation, and component failure must be visible states rather
than booleans or log messages. Capture implementations also need a common objective Event envelope
without creating a generic payload escape hatch for prohibited screen or input data.

The state contract must distinguish a whole-stream Session boundary from an ordinary failure of
one optional collector. Otherwise a transient weather or browser collector issue could
mechanically fragment an otherwise continuous Session.

## Decision

`EventID` and `DisplayID` are distinct opaque UUID-backed value types. Platform display handles are
mapped to `DisplayID` outside Core and are not persisted as domain identity.

Each `CollectorState` combines a `CollectorKind`, an `AuthorizationState`, and one explicit
`CollectorRuntimeState`: unconfigured, waiting for authorization, running, paused, degraded, or
failed. Denied and revoked authorizations remain distinct. Unknown, denied, restricted, revoked,
and not-determined authorization fail closed into waiting rather than being treated as a
collector crash.

Pauses retain both a non-empty set of active `CollectionPauseReason` values and the safe state to restore.
This handles real nested boundaries such as lock followed by sleep: waking does not resume
collection until the screen is also unlocked. Authorization changes while paused update the
restoration target, so unlock cannot restart a collector whose permission was revoked.

`CollectorStateMachine` is a pure transition policy. Its result states whether a currently active
Session must end. The first screen lock, system sleep, explicit global user pause,
privacy/secure-input pause, or loss of a previously usable authorization creates a hard boundary;
nested or duplicate pauses are still audited but do not end a second nonexistent Session. An ordinary per-collector
degradation or failure does not, by itself, end a cross-collector Session; a future collection-wide
failure must be represented by an explicit global boundary action.

`ObjectiveEvent.occurredAt` and optional `endedAt` are absolute `Date` values. Civil-time day
assignment remains the responsibility of `WorkdayBoundary`; Event does not cache a mutable
`DayID`. The minimal envelope also contains collector source/version, kind, IANA time-zone
identifier, optional typed display/topology context, and a privacy-gate disposition containing
only a stable safe reason.

Collector version strings are bounded machine identifiers with a narrow ASCII character set, and
all event timestamps must be finite. Custom decoding revalidates these invariants and rejects
CollectorState combinations that could bypass fail-closed authorization or paused-state rules.

`ObjectiveEvent` intentionally has no generic payload, OCR text, screenshot bytes, key event,
pointer event, free-form diagnostic message, goal, emotion, productivity, or focus field.
Privacy-reviewed aggregate, evidence, and context records must be separate types linked by
`EventID`.

## Alternatives considered

- **One enabled boolean per collector:** cannot distinguish consent, pauses, degradation, or
  recoverable failure and invites repeated permission prompts.
- **One pause reason:** loses nested lock/sleep state and can resume collection too early.
- **A generic dictionary or data payload on Event:** flexible, but bypasses compile-time privacy
  review and can persist raw input or screen content.
- **Every collector failure ends Session:** simple, but incorrectly fragments work when an optional
  sensor such as weather or Chrome metadata temporarily fails.
- **Persist DayID on Event immediately:** convenient for queries, but duplicates a derived value
  whose meaning changes with workday-boundary migration.

## Privacy impact

The closed Event envelope makes prohibited raw input and screen payloads unrepresentable there.
Suppressed observations retain only a stable exclusion reason, never the sensitive pixels or text
that triggered it. Authorization and pause transitions fail closed, including when revocation
happens during a lock or sleep.

## Migration impact

This is the first version of these Core contracts. Persistence must encode identifiers as UUIDs
and runtime/event enums using explicit schema versions rather than depending on compiler-generated
case ordering. Changing identifier meaning, boundary rules, or adding payload-bearing Event fields
requires a follow-up ADR and storage migration.

## Consequences

- Capture coordinators can use one deterministic state policy and the UI can explain why each
  collector is not running.
- Nested pause handling adds a small amount of state but prevents premature resume.
- Event-specific data requires explicit, reviewed types instead of opportunistic dictionaries.
- Session construction consumes explicit boundary decisions and does not infer them from every
  local collector error.
