# ADR 0035: Journal fragment persistence

## Status

Accepted.

## Context

Separate from the day-anchored journal entry, users capture lightweight passing thoughts that gather
throughout the day with no fixed structure. A fragment is a short, immutable, user-authored note
(`body` + `createdAt`) tied to its logical day. Like the journal entry, fragments are a
user-owned personal artifact that must never be read by the work report and must never be
rewritten or normalized by AI.

## Decision

- New `JournalFragmentRepository` protocol in `DaydayCore` provides:
  - `insert(_:)` storing a fragment and returning `.inserted` or `.alreadyPresent`, making saves
    idempotent without violating immutability.
  - `fragments(for:)` returning a day's fragments oldest first.
  - `recentFragments(limit:)` ordering across days newest first, failing closed on invalid limits.
- `SQLiteJournalFragmentRepository` in `DaydayStorage` persists fragments in a dedicated versioned
  `journal_fragment_*` namespace (schema version 1) with a schema fingerprint and migration
  journal, mirroring the journal-entry and work-report repositories. The fragment is the
  immutable unit: re-inserting an identical fragment is a no-op, and the stored payload is
  canonical-encoded JSON that is round-trip validated on read.
- `ProductionDataStore` constructs the fragment repository so it boots alongside the other
  namespaces.
- `JournalFragmentModel` in `DaydayApp` owns a draft field plus an append-only list. It loads the
  current logical day's fragments on bootstrap and appends a new immutable fragment via `addFragment`,
  reusing the same stable logical-`DayID` derivation as the journal entry and work report so all
  sibling artifacts share a deterministic day identity while staying strictly separate stores.
  An all-whitespace draft is ignored and never persisted.
- Strict type isolation from work is unchanged: fragments never enter the `WorkReportContext`
  allowlist, and `WorkReportJournalIsolationTests` remain in force.

## Privacy impact

Fragments are durable retention of short user-typed notes — an explicit, user-owned personal
artifact, isolated from the work report by types and tests. No input-event reconstruction,
screenshots, or inference produce fragments.

## Migration impact

New SQLite namespace `journal_fragment` (schema version 1). Existing databases need no migration;
the namespace is created on first open. Journal-entry, work-report, and captured-objective
namespaces are untouched.

## Alternatives

- Reuse the journal entry toward fragments: rejected, because a fragment is append-only and has no
  lineage/versions, while an entry is editable with an immutable original lineage — merging them
  would conflate two distinct continuity models.
- Store fragments in the journal-entry tables: rejected, because it couples immutable versions to
  append-only notes and weakens the entry/fragment modeling boundary.