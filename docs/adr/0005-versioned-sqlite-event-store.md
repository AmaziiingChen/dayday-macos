# ADR 0005: Versioned SQLite objective event store

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Objective collector events must survive process restarts without turning the closed Core envelope
into an arbitrary persistence channel. The first database format also establishes migration and
corruption behavior that later repositories will need to follow.

## Decision

`ObjectiveEventRepository` is a Core protocol. Its fetch operation selects events whose
`occurredAt` lies in a half-open range `[lower, upper)`, rejects invalid or non-finite ranges, and
returns a stable order by occurrence time and opaque event identifier.

`SQLiteObjectiveEventRepository` uses the system `libsqlite3`; no network package is introduced.
It supports in-memory databases for isolated use and caller-selected file URLs for production and
tests. Each write runs in an immediate transaction. `EventID` is the primary key: inserting an
identical event again succeeds as `alreadyPresent`, while reusing that identifier for different
content fails without overwriting the stored observation.

The SQLite schema stores every field in an explicit, typed column: event and display identifiers,
event kind and timestamps, IANA time-zone identifier, collector kind/version/payload schema,
topology revision, security disposition, and safe suppression reason. It has no payload, OCR,
screen image, input-event, diagnostic-message, or secret column. Swift's synthesized `Codable`
representation is an interchange convenience and is not the long-term disk schema.

The database contains both a singleton schema version and an append-only migration journal.
Schema creation and migration bookkeeping are one transaction. A missing/inconsistent journal,
unknown newer schema version, unknown enum, invalid identifier, invalid civil-time value, or other
corrupt row fails closed. The repository never deletes, recreates, or silently repairs such data.

Event instants are encoded as finite seconds since Apple's 2001 reference date. This is the exact
`Double` representation used internally by Foundation `Date`, avoiding the precision loss that can
occur when translating through Unix-epoch seconds. Display topology revisions use canonical decimal
text so the full `UInt64` domain survives SQLite's signed 64-bit integer limit.

On every open, the repository validates a normalized schema fingerprint for all v1 tables and the
required range-query index before accepting the migration ledger. A missing or altered column,
type, primary key, check constraint, `STRICT` marker, or index fails closed as schema corruption.

## Alternatives considered

- **JSON/Codable blob per event:** easy to add, but makes fields unqueryable, couples storage to
  compiler-generated encoding, and creates an attractive arbitrary-payload escape hatch.
- **SQLite row ID identity:** compact, but conflicts with opaque UUID-backed domain identifiers and
  complicates import/merge idempotency.
- **`CREATE TABLE IF NOT EXISTS` without migrations:** convenient initially, but cannot prove which
  semantics produced existing rows or safely evolve them.
- **Replace a duplicate ID:** loses objective history and lets retries rewrite observations.
- **Third-party SQLite wrapper:** reduces boilerplate but adds license, supply-chain, and
  replacement costs before the persistence requirements justify it.

## Privacy impact

The schema makes the minimal ObjectiveEvent envelope auditable and does not include a generic data
field. Suppressed observations preserve only the accepted stable reason. Database errors contain
SQLite operational context but callers must not put captured content or secrets into SQL or bind
values outside the reviewed columns.

## Migration impact

This creates schema version 1. Every later schema change must add a numbered, transactional
migration and preserve the journal. Applications must refuse a newer unknown database rather than
downgrade it. Import/export remains a separate versioned format.

## Rollout plan

Use the in-memory location in unit tests and temporary files under `/tmp` for migration/corruption
tests. The app composition root uses `SecureDatabaseLocation` to prepare an owner-only Application
Support URL and must surface preparation/open/migration errors without automatically resetting
user data. The preparer also validates links, owners, file types, ACLs and SQLite sidecar modes.

## Consequences

- Range queries and duplicate retries are deterministic and testable.
- Explicit mapping code must be updated when the closed event contract evolves.
- Direct C SQLite use is replaceable behind the Core repository protocol but requires careful
  statement lifecycle and error handling.
