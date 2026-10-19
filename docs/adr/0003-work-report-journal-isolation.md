# ADR 0003: Isolate work reports from personal journals

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday serves two distinct purposes. The work report summarizes professional activity and may be
shared externally. The personal journal preserves the user's subjective writing, fragments,
attachments, mood, and environmental context. The artifacts can exist on the same Day in any order,
but private thought or emotion must never leak into a work report.

Prompt instructions alone are insufficient isolation: an accidental broad database query could put
journal text into model context before the prompt is applied.

## Decision

- Model WorkReport and JournalEntry as independent sibling artifacts under a Day. Neither requires
  the other to exist or be final.
- Define a purpose-specific, allowlisted `WorkReportContext` and repository projection that can contain
  Activities, work notes, allowed calendar/reminder summaries, confirmed todos, and their objective
  evidence references. It may also contain WeatherSnapshots as objective environment data.
- The projection cannot represent or return JournalEntry text, JournalFragments, journal
  attachments, or MoodEntries. Work-report provider adapters accept only this typed context.
- Weather is environmental context. It may be displayed alongside either artifact and supplied to
  work-report generation as an objective snapshot, but it is not automatically inserted into prose
  and cannot be used to infer mood or causation.
- The journal editor may show a default-collapsed, read-only work-background panel. Viewing the
  panel does not copy content into the journal.
- Journal text is user-authored and preserved exactly. An explicit AI rewrite, continuation, or
  organization action creates a labeled derived version and never overwrites the original.
- External Agent work-context API/MCP endpoints use the same work-safe projection.

## Alternatives considered

- **One combined daily document:** simpler navigation, but makes professional/private boundaries
  ambiguous and increases accidental disclosure risk.
- **Prompt-only instruction not to use journal text:** flexible, but not enforceable or testable at
  the data-access boundary.
- **Generation-order dependency:** requiring a report before a journal (or vice versa) does not
  match actual use; either may be written throughout the day.
- **Optional per-generation consent to quote the journal:** rejected because the intended product
  semantics do not include journal-to-work-report flow at all.
- **Automatic AI-authored journal:** conflicts with preserving subjective wording, mistakes, tone,
  and emotion in the user's original voice.

## Privacy impact

This is a strong privacy boundary. Private writing and mood are structurally absent from work
generation and work-context external APIs. Journal images are not submitted to visual models by
default. Tests can validate serialized work-report requests without relying on model behavior.

## Migration impact

Storage may use one database, but repository queries and serialized types remain domain-separated.
A future feature that allows journal content to influence work reports would reverse an explicit
product decision and requires a new ADR, schema/API review, migration plan, and affirmative user
decision; it cannot be introduced as a prompt or UI-only change.

## Consequences

- Some Day-level presentation and search code must compose two repositories instead of using a
  single daily-document model.
- The work-report pipeline is easier to audit, test, and expose safely through MCP.
- Journal AI features need their own provider task and usage entry.
- Weather, mood, and journal fragments can enrich personal reflection without becoming professional
  report input.
