# ADR 0048: Journal AI uses explicit, independent derived versions

## Status

Accepted on 2026-08-11.

## Decision

Dayday exposes four full-document Markdown operations in the journal: organize, rewrite,
continue writing, and proofread. A custom instruction is an additional constraint on rewrite.
The editor is snapshotted before every request so recently composed text is included without
moving model calls, counting, or persistence into the hot IME input path.

Every successful response is persisted as `JournalDerivedVersion` with the source original,
operation, model, provider, prompt version, and creation time. Generation never overwrites the
user-authored original. The original changes only after the user previews and explicitly accepts
a derived version; the ordinary single-original autosave then persists that accepted body.

The journal SQLite namespace advances from schema version 1 to 2. Version 2 adds a strict derived
version table and an entry/creation-time index. Existing version-1 databases migrate in place and
retain the entries and originals tables unchanged.

Generation is bound to the source logical day. Changing the selected day cancels the visible
operation, discards stale presentation state, and prevents an older result from being accepted
into the newly selected journal. Recent-version menus use a bounded query; older bodies stay on
disk instead of accumulating in the editor process.

The first integration uses Dayday's existing BYOK OpenAI-compatible text-model configuration.
The provider receives only the journal text involved in this explicit operation, never implicit
work-report context. Work-report generation remains unable to read journal artifacts.

## Consequences

- Model output is recoverable, attributable, and safe to reject.
- Re-generation creates another independent copy instead of destroying an earlier result.
- The first slice operates on the full document. Selection-aware replacement can be added later
  only when MarkEdit exposes a stable range contract across rich-preview and source modes.
- MarkEdit's own extension ecosystem remains a reference; Dayday does not require a second model
  credential path or an OS-version-specific Apple Intelligence dependency.
