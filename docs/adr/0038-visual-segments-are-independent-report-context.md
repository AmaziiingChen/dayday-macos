# ADR 0038: Visual work segments are independent work-report context

- **Status:** Accepted
- **Date:** 2026-08-08

## Context

Visual work segments previously entered `WorkReportContext` only by being concatenated into an
objective Activity's free-form summary, or by manufacturing a fallback Activity when no objective
activity existed. That lost the distinction between an observed fact and a visual-model inference,
omitted visual work when objective activities did exist but did not overlap, and made it impossible
for the report model to apply confidence and uncertainty consistently.

## Decision

`WorkReportContext` carries `visualSegments` as a separate, bounded allowlisted collection.
Each segment retains its interval, typed `VisualWorkSegment`, and local visible-observation IDs.
It never becomes an Activity and cannot contribute interaction duration or a completion claim.

The text-only report provider receives these structured fields in the closed JSON context and is
instructed to omit or qualify low-confidence and `uncertain` visual material. Source references
include the segment observation IDs without retaining screenshot bytes.

## Consequences

- A visual segment is available to the daily report even when objective Activity derivation is
  incomplete.
- The provider can distinguish facts, visual inferences, and uncertainties without parsing a
  formatted summary string.
- Existing reports stay readable; this changes only generation-time context and source lineage for
  newly generated revisions.
