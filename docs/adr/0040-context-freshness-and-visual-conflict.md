# ADR 0040: Visual context is time-scoped and conflicts are typed

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The visual request already carries a privacy-filtered foreground application and window title, but
it previously presented every retained app-context event as current. A fast app switch can make a
recent WeChat observation look authoritative while the visible frame belongs to another
communication application. The prompt asked a provider to mention conflicts in prose, which made
the conflict hard to validate, aggregate, and keep out of a factual report claim.

## Decision

Each visual time slice classifies its deterministic system context as `current`,
`recentlyObserved`, or `unavailable`. Only an application-context event observed within 20 seconds
is current. A 20–120 second event is a useful disambiguation hint, never proof of the current
foreground application; older or absent context is unavailable. The provider receives that status
with each time slice, as well as the existing bounded application label, filtered title, OCR, and
per-display frame metadata.

The strict visual result gains `system_context_agreement`: `matches`, `conflicts`, or
`unavailable`. A request with a current system context must return `matches` or `conflicts`; a
request without one must return `unavailable`. The runtime stores this marker on the
`VisualWorkSegment`, copies an application label into the durable segment only while the context
is current, and carries conflicts forward as an uncertainty. The text-report prompt treats a
conflicted visual segment as uncertain and may not turn it into an app-specific factual statement.

The capture policy remains hybrid: a low-frequency 60-second per-display fallback is supplemented
by coalesced foreground-app and Return/Enter anchors. Anchors still require the same local safety,
redaction, deduplication, and size checks; they do not carry input content.

## Alternatives

- Treat every recent application event as authoritative. Rejected because its stale state is the
  observed cause of app-surface confusion.
- Ask the model to write a conflict sentence without a typed field. Rejected because reports and
  diagnostics cannot reliably interpret free-form text.
- Send provider conversation/cache state between requests. Rejected because it is opaque and not
  a durable local source of truth.

## Privacy impact

No new raw data is captured or persisted. Context freshness is derived locally from an already
allowed app-context timestamp. The provider receives no new identifiers, and Return/Enter remains
a content-free capture request.

## Migration impact

`VisualWorkSegment` decodes records that predate the agreement marker as `unavailable`; no SQLite
migration is required. New visual observation payloads use schema version 3.

## Consequences

- The visual model has explicit temporal limits for system facts and must surface disagreement.
- DeepSeek continues to receive structured visual summaries, never screenshots, and gets a stable
  report outline plus the typed uncertainty boundary.
- Quality can now be evaluated with concrete app-mismatch cases instead of searching model prose.
