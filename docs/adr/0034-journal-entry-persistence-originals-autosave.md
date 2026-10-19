# ADR 0034: Journal entry persistence, immutable originals, and autosave

## Status

Accepted.

## Context

The journal was an in-memory interaction prototype: `JournalView` bound a `TextEditor` to
`AppDraftStore.journalText`, and the page explicitly warned that edits were not written to disk.
H4 required real persistence and autosave, while the product and privacy contracts require that a
journal original is exact user-authored text that is never rewritten or normalized by AI, and that
the work report never reads journal content. The isolation is already enforced at the
`WorkReportContext` allowlist and by `WorkReportJournalIsolationTests`; this slice adds the durable
journal store that the view should drive.

## Decision

- New `JournalEntryRepository` protocol in `DaydayCore` provides:
  - `save(_:)` storing the current exact original of a journal entry and appending the version to an
    immutable per-day originals lineage. Inserting a new day or advancing a draft to its next exact
    user-authored version both go through this method.
  - `entry(for:)` returning the current persisted journal entry for a logical day.
  - `originals(for:)` returning the immutable user-authored originals lineage, oldest first.
  - `recentEntries(limit:)` ordering journal days by updated time.
- `PersistedJournalEntryRecord` validates that the `DayDescriptor` equals the entry's day and that
  the current original is exactly the version the entry points at (`currentOriginalVersionID` and
  `currentOriginalVersionNumber`).
- `SQLiteJournalEntryRepository` in `DaydayStorage` persists both the entry (indexed by stable
  `day_id`) and each immutable original in a dedicated versioned `journal_artifact_*` namespace with
  a schema fingerprint and migration journal, mirroring the work-report repository. Lineage
  validation (entry ID, created date, monotonic version + saved date, previous-version match)
  rejects out-of-order updates in a transaction.
- `ProductionDataStore` constructs the journal repository so the app boots it alongside the other
  namespaces.
- `JournalEntryModel` in `DaydayApp` owns the editor text. It restores the current logical day on
  bootstrap and debounces autosave (default 700 ms), appending a new immutable original whenever the
  content advances. It uses the same stable logical-`DayID` derivation as the work report so a day's
  entry and report share a deterministic day identity while remaining strictly separate stores.
  `flushPendingAutosave()` runs on shutdown so the last keystrokes are never lost.

Journal originals retain their exact body; the model trims only for the purpose of deciding whether
an entry is empty (an all-whitespace body triggers no persistence), and never trims the stored
text.

## Privacy impact

This adds durable retention of exactly what the user typed in the journal — an explicit,
user-owned personal artifact. It must never enter the work-report allowlist, and the isolation is
unchanged and still enforced by types and `WorkReportJournalIsolationTests`. No input-event
reconstruction, screenshots, or inference feed the journal.

## Migration impact

New SQLite namespace `journal_artifact` (schema version 1). Existing databases need no migration;
the namespace is created on first open. Work-report and captured-objective namespaces are
untouched.

## Alternatives

- Keep the journal as a plain text file (like the work note): rejected, because lineage and
  immutable original versions (needed for fragments, corrections, and AI-derived copies later) are
  first-class requirements.
- Persist only the latest text with no lineage: rejected, because the domain already models
  `JournalOriginalVersion` lineage and H4 requires exact-original preservation.
- Store the journal inside the work-report tables: rejected outright, because it would break the
  required report/journal type isolation.