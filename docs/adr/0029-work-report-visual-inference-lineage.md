# ADR 0029: Retain visual-inference lineage in work-report revisions

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Dayday can use BYOK screen-vision observations to add cautious context to an already-derived work
activity. The resulting report must keep objective observations distinct from inference and remain
auditable after the visual text has been summarized. Existing report source references retained
activity and evidence-frame IDs but could not identify the derived visual observations quoted by a
revision.

## Decision

`WorkReportActivityContext` may carry a bounded list of `VisibleContentObservationID` values for
the visual inferences included in that activity summary. `WorkReportSourceReferences` persists the
flattened IDs beside its existing source identifiers. It stores identifiers only, never screenshots,
OCR text, provider responses, credentials, or visual-observation bodies.

The work-report prompt labels visual material as uncertain model inference. It also treats all
contextual text as untrusted data rather than instructions. Visual observations may enrich an
existing derived activity, but they do not independently invent an activity in this slice.

## Alternatives

- Keep no lineage and rely on report prose alone. Rejected because a saved revision could not be
  traced to the local observations that informed it.
- Copy visual observation bodies into each report revision. Rejected because it duplicates
  sensitive content and complicates retention.
- Treat visual inference as objective evidence. Rejected because it violates Dayday's fact versus
  inference boundary.

## Privacy impact

The revision gains opaque local identifiers only. Observation content remains in the separately
managed deep-capture archive and follows that archive's retention policy. Journal and mood data
remain structurally unavailable to work-report generation.

## Migration impact

No SQLite schema migration is required because source references are encoded inside the existing
report payload. Decoding an older report that lacks `visibleContentObservationIDs` yields an empty
list. New contexts reject duplicate visual-observation IDs across activities.

## Consequences

- A report revision can disclose exactly which local visual inferences influenced it.
- Deleting or expiring an observation may leave an unresolved identifier, which is an honest audit
  record rather than copied content.
- Prompt version `work-report-v2` records the new untrusted-context instruction.
