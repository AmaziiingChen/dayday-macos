# ADR 0043: Journal realtime save updates one original, not a revision stream

## Status

Accepted.

## Context

The first journal persistence slice treated every debounced autosave as a new immutable
`JournalOriginalVersion`. This conflated a durability mechanism with an intentional authoring
decision: a few minutes of normal typing could show dozens of misleading “versions”. The owner
requires continuous local saving, but does not want a save counter or automatic original-history
feature.

## Decision

- A journal day has one current exact user-authored original. Realtime save updates that record in
  place, preserving its identifier and internal version number.
- The interface reports only local save state (for example, “已自动保存到本机”); it never reports an
  autosave as “第 N 版”.
- Explicit AI organize/rewrite/continue actions remain separate `JournalDerivedVersion` records.
  They retain their model, time, operation, and source-original reference, and cannot overwrite
  the current original.
- Existing databases are not destructively compacted. Prior automatic original rows remain for
  preservation, but new typing never creates them and the journal UI does not expose them as a
  revision feature.

## Privacy and migration impact

No new data is collected or sent. The SQLite schema remains compatible: the current original row
is updated atomically with its entry payload. Existing data is retained rather than deleted; a
future user-directed history cleanup/export flow would need its own deletion and recovery design.

## Alternatives

- Keep incrementing versions but hide the number: rejected, because it still stores a misleading
  and rapidly growing history.
- Snapshot every edit on a longer timer: rejected, because it retains the same unwanted product
  behavior and adds storage churn.
- Disable autosave and require a Save button: rejected, because it weakens the private writing
  experience and risks data loss.
