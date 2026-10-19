# ADR 0042: SQLite-backed companion health queue

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The original Companion queue encoded all retained facts in one protected JSON file. It was adequate
for a four-type probe but fails a real all-history import: every small HealthKit page decoded,
modified, and rewrote every previously imported record. High-frequency Apple Watch observations
therefore made progress increasingly slow and could starve the user interface.

## Decision

The Companion stores its private source queue in SQLite in its Application Support container. Each
anchored HealthKit page is applied in one SQLite transaction: records upsert by HealthKit UUID,
deleted UUIDs remove observations and upsert tombstones, then and only then does the caller commit
the HealthKit anchor. Queue status reads counts and the most-recent 50 facts directly in SQL.

The old v1 JSON queue migrates transactionally before the first SQLite operation. Its legacy file
is retained as an app-private recovery copy; successful migration is recorded in SQLite metadata
so it cannot duplicate observations on later launches.

## Consequences

- Import cost is proportional to the changed page, rather than the entire imported history.
- The queue remains Companion-private, local-only, and separate from the future Mac schema or LAN
  wire format.
- No third-party dependency is added: the target links Apple-platform `libsqlite3` only.
