# ADR 0013: Fail-closed input aggregate SQLite storage

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

ADR 0006 defines a privacy-closed `InputAggregate`, and ADR 0011 keeps raw key and pointer samples
inside a memory-only Capture boundary. Durable storage must preserve that separation. It also has
to survive retries, corrupted files, future schema versions, civil-time edge cases, and crashes
during hour-to-day compaction without deleting the evidence required to rebuild a daily aggregate.

The existing objective-event repository owns a different version-one schema and migration ledger.
Reusing its generic metadata tables or adding input counters to `objective_events` would couple two
independent persistence contracts and make either migration capable of damaging the other.

## Decision

`SQLiteInputAggregateRepository` accepts and returns only validated `InputAggregate` and
`DailyInputRollupPlan` values. It exposes no raw sample, key event, pointer event, screenshot,
generic payload, or capture callback API. Production composition must inject a dedicated database
file. All schema objects are additionally namespaced `input_aggregate_*`, so an accidentally shared
development file does not collide with the objective-event v1 tables.

Schema version one stores bounded query metadata—ID, absolute period start/end, granularity, IANA
time-zone identifier, optional workday-boundary hour, and payload schema version—beside a canonical
sorted-key JSON encoding of the closed aggregate. Every read:

1. rejects an unknown payload version;
2. decodes through Core, re-running all aggregate, period, DST, grid, identity, and version checks;
3. re-encodes and byte-compares the canonical JSON, rejecting unknown or noncanonical fields; and
4. verifies every duplicated metadata column exactly matches the decoded payload.

The schema has its own monotonic migration journal, version row, definition validation, and an
FNV-1a fingerprint derived from normalized schema SQL. A newer version, partial namespace,
fingerprint mismatch, missing/replaced table or index, invalid ledger, malformed payload, or
metadata disagreement fails closed without rewriting the file. Unexpected objects inside the
`input_aggregate*` namespace also fail validation, preventing an unversioned trigger or shadow
table from silently changing repository semantics.

Insertion is idempotent by `InputAggregateID`: identical content returns `alreadyPresent`; different
content with the same ID is an explicit conflict. Period queries use `period_start >= lower AND
period_start < upper`, validate finite non-empty bounds, and order by start then UUID.

Applying a `DailyInputRollupPlan` uses one `BEGIN IMMEDIATE` transaction. The repository loads all
declared hourly sources, recomputes the daily aggregate with Core policy, and requires the recomputed
value and ordered source IDs to equal the plan. It then inserts the daily row before deleting each
declared source ID individually, requiring exactly one deletion per source. A missing source,
content mismatch, daily ID conflict, decode error, or deletion anomaly rolls back both insertion and
deletion. A retry after a committed transaction returns `alreadyApplied` only when the exact daily
row exists and every declared source is absent.

File-backed repositories request WAL mode and keep SQLite full-mutex and busy-timeout behavior. File
ownership, symlink defense, ACL removal, and sidecar permissions remain the responsibility of the
separate secure-location composition before this repository is opened.

## Alternatives considered

- **Persist transient key or pointer samples:** rejected because event order and precise interaction
  detail would cross the privacy boundary and become replayable history.
- **Add input fields to `objective_events`:** rejected because that schema models timestamped facts,
  not already-coarsened hour/day values, and has an independent migration lifecycle.
- **Store only JSON:** rejected because bounded period queries would require decoding every row and
  could not use a stable index.
- **Trust duplicated columns without checking payload:** rejected because tampering or a partial
  migration could make queries return a value under false time-zone or period semantics.
- **Decode JSON while ignoring unknown keys:** rejected because a future or malicious raw field
  could survive storage while remaining invisible to the current Core decoder.
- **Delete source hours before writing the daily aggregate:** rejected because a crash or conflict
  would permanently lose the only durable source values.
- **Trust only the source IDs in a rollup plan:** rejected because the stored rows might differ from
  the aggregates used to construct that plan; recomputation proves content equality before deletion.

## Privacy and security impact

Only aggregate totals already permitted by ADR 0006 become durable. Typed text, characters, key
order, modifier sequences, exact event timestamps, exact pointer coordinates, pointer paths,
per-key-per-application joins, raw screenshots, titles, URLs, and document content remain
unrepresentable. Canonical revalidation rejects an injected unknown field instead of silently
round-tripping it.

Transactions prevent partial compaction, checked Core decoding prevents corrupted counters or
periods from becoming trusted facts, and namespaced metadata prevents this repository from taking
ownership of unrelated user tables. SQLite error text must not be logged together with payloads.

## Migration impact

This is input-aggregate schema and payload version one. There is no released data to migrate.
Changing table definitions, metadata duplication, canonical encoding, payload fields, query
semantics, or rollup deletion rules requires a registered migration, a new fingerprint, and an ADR
update. A future JSON encoder change that alters canonical bytes must be handled as a payload
migration rather than weakening canonical validation.

## Rollout

1. Land the isolated repository and in-memory/file-backed tests without connecting a live input
   adapter.
2. Add a secure dedicated production location and Capture-to-Storage flush coordinator in a
   separately reviewed slice.
3. Add the retention scheduler only after crash recovery and daily compaction integration tests
   pass on an actual app bundle.
4. Keep backup, import/export, UI, networking, and raw capture outside this slice.

## Consequences

- Safe aggregates can survive restart and support deterministic time-range charts.
- Daily compaction is retryable and cannot silently delete mismatched or unrelated hours.
- Canonical payload checks are intentionally strict and require explicit migrations when encoding
  changes.
- The implementation duplicates a small SQLite wrapper to keep error and schema ownership isolated;
  consolidation may occur later only through a reviewed neutral storage primitive.
