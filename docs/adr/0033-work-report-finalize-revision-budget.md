# ADR 0033: Work-report finalization, revision lineage, and token-budget gating

## Status

Accepted.

## Context

A work report draft is a user-editable AI output. Two capabilities were missing before this slice:
a durable "finalized" state that the automatic scheduler must respect, and a user-visible token
budget so BYOK generation cannot silently consume an unbounded amount of provider usage. The work
report already persisted an immutable revision chain; the product needed a first-class status
transition and aggregate usage query on top of it.

## Decision

- `WorkReportRepository` gains three capabilities:
  - `finalize(_:)` performs a status-only transition of a draft to `.final`, inside a transaction,
    requiring a current-revision match; it never appends a revision and rejects an already-final
    report.
  - `revisions(for:)` returns the immutable revision lineage for a report, oldest first, for a
    version-history UI.
  - `tokenUsage(in:)` aggregates provider-reported successful usage rows whose completion time
    falls in an interval, for budget gates and usage statistics.
- Finalization is a pure local state transition. A finalized report blocks automatic model
  regeneration in the domain (`generateIfScheduledAndAbsent`) and the UI surfaces it as "已定稿"
  with regeneration and editing disabled.
- A token budget is modeled as `WorkReportTokenBudget` (daily and/or monthly provider-reported
  token caps). It only gates whether an AI generation may start; it never stops local collection.
  The automatic scheduler (`WorkReportAutoSchedule`, default end hour 18:00) only fires when no
  draft exists for the logical day and the budget has not been exhausted.
- Writing preferences (`WorkReportWritingPreferences`) are user-authored, stored locally, and
  injected into the generation prompt as an additive parameter. They never enter the
  `WorkReportContext` allowlist projection, so the work-safe contract is unchanged.
- Export of a report uses a pure `WorkReportMarkdownExporter` that renders bounded front matter,
  the current revision body, and opaque metadata (revision, status, provenance). Journal and mood
  content cannot be reached from this type.

## Privacy impact

None of the new paths adds content retention. `tokenUsage` aggregates only provider-reported
token counts; `revisions` returns immutable revision bodies that were already persisted. The
Markdown exporter emits only the current revision body and opaque identifiers.

## Migration impact

SQLite schema is unchanged. The new `finalize`, `revisions`, and `tokenUsage` methods are additive
query/update capabilities over existing rows; existing stored reports need no migration.

## Alternatives

- Store a separate `finalized` flag decoupled from the report row: rejected, because finalization
  is a property of the report and must be atomic with its revision.
- Enforce budget purely in the scheduler: rejected, because manual generation must honor the same
  gate.
- Include writing preferences inside `WorkReportContext`: rejected, because that would widen the
  work-safe allowlist contract; preferences are injected additively at the prompt boundary instead.
