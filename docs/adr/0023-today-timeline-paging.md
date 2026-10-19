# ADR 0023: Cursor-paged Today timeline reads

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Application/window collection can create many objective facts in one workday. Reading every row,
then building every SwiftUI timeline row and linked projection, makes Today slow to enter and can
keep work running after the user switches to another section.

## Decision

Core exposes an optional newest-first `ObjectiveEventPageRepository` read capability. Its cursor is
the existing event occurrence time plus opaque event ID, which gives a strict deterministic boundary
without adding persisted fields. SQLite returns a bounded page plus a cursor only when an older page
exists. Today first reads 60 facts, renders rows lazily, and requests older pages only when the user
asks. Leaving Today cancels an in-flight page request; cancellation never affects H1 collection or
durable SQLite facts.

Application-context projections are fetched only for events in pages the user has opened. Today
rebuilds its existing objective-only presentation from the loaded pages; it does not infer Sessions
or Activities, change evidence retention, or expose raw data.

## Alternatives considered

- Fetch all events and hide old rows: rejected because database and projection work still blocks
  first render.
- Offset pagination: rejected because concurrent inserts shift offsets and can duplicate or skip
  facts.
- Cancel H1 collection on navigation: rejected because UI navigation must not change durable
  collection consent or runtime state.

## Privacy and migration impact

The cursor contains only an existing objective timestamp and opaque event ID. No schema migration,
new persistence, raw event, application identity, title, text, or external request is introduced.
Existing authorization, pause and negative-control behavior is unchanged.

## Rollout

SQLite paging is covered with deterministic equal-timestamp ordering tests. Today keeps the old
repository read as a compatibility fallback for repositories that do not implement the optional
capability, while production SQLite uses paging immediately.
