# ADR 0016: Production data-store composition

## Status

Accepted for the v0.1 implementation.

## Decision

`ProductionDataStore.open` is the only production composition path for durable objective events
and input aggregates. It first delegates filesystem creation and validation to
`SecureDatabaseLocation`, opens the two independently versioned repository namespaces in the same
SQLite file, then reapplies owner-only permissions to the database and any SQLite sidecars.

Feature code receives repository actors from this composition and cannot select arbitrary file
URLs. An internal seam lets `@testable` tests inject a private Application Support base directory.

## Privacy and failure behavior

- The input repository has no raw event API and its schema stores only closed aggregates.
- The objective repository stores only the previously accepted privacy-filtered event envelope.
- Partial, unknown, or modified schema objects fail closed in their owning namespace.
- Symlinks, hard links, unsafe ownership, shared writable bases, and extended ACLs are rejected by
  the secure-location layer before data is trusted.
- SQLite-created WAL, SHM, and rollback-journal artifacts are reconverged to owner-only access.

## Deferred work

Crash-consistent rolling backup and verified restore remain a separate slice. They must use the
SQLite backup API or an equivalent database snapshot while repositories are quiesced; copying a
live database file directly is not acceptable.
