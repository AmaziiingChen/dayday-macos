# ADR 0011: Memory-only input accumulator boundary

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

ADR 0006 defines the only persistable keyboard and pointer aggregate shape, but a platform event
adapter still needs a concurrency-safe place to coarsen transient interaction facts before storage.
Publishing event-shaped values, retaining exact pointer paths, or allowing excluded samples to
create even empty buckets would weaken that contract before a repository is involved.

Civil-hour bucketing is also not equivalent to dividing Unix time by 3,600. Local hours must remain
correct across daylight-saving gaps and repeated hours, while an exact hour boundary belongs to the
new bucket. Multi-display users require display identity and topology revision to remain separate.
Application context may change frequently, but it may contribute only totals keyed by the existing
opaque `ApplicationIdentifier`.

## Decision

`DaydayCapture` owns an actor-isolated `InputAggregationAccumulator`. Its public surface contains
only validated configuration, aggregate-only snapshots, and a completed-hour flush operation. Raw
sample types and record methods are module-internal and have no `Codable`, logging, description, or
public protocol conformance.

Transient physical-key samples contain only an observation instant, a `UInt16` hardware identity,
an optional opaque application identifier, and a bounded layout version. They contain no character,
text, modifier sequence, or exportable order. The output keeps global unordered physical-key totals
and independent per-application total key counts; it cannot associate a particular key with an
application.

Transient pointer samples contain one normalized display location, an opaque `DisplayContext`, an
optional opaque application identifier, and one closed action:

- left/right/other click;
- non-negative directional scroll magnitude;
- integer distance in milli-points; or
- integer coarse-cell dwell milliseconds.

The exact transient normalized location is immediately reduced into a bounded configured grid and
is never returned. Display totals are keyed by both `DisplayID` and topology revision. Application
pointer values contain totals only; dwell has no application-level field and therefore does not
create a zero-valued application record.

Every record call receives the existing `EventSecurityDisposition`. Anything other than `allowed`
returns before bucket creation or mutation, so secure input, global pause, screen lock, exclusions,
and metadata-only contexts contribute exactly zero counts, duration, and metadata.

The accumulator delegates period creation to Core's single canonical civil-hour factory. That
factory combines nominal local hour starts with actual time-zone transition instants and uses only
adjacent, sorted boundaries. Repeated and skipped time are therefore represented by disjoint
absolute periods, including 30-minute transitions such as Australia/Lord_Howe. Exact boundaries
start the next period. Coverage intervals are split at those same boundaries, coalesced as interval
unions within each bucket, and contribute integer milliseconds only. Overlapping coverage samples
cannot double-count time.

Mutation is transactional. A candidate bucket map is changed and committed only after every checked
addition and invariant succeeds. `UInt64` overflow, invalid timestamps, invalid locations, excessive
coverage, and aggregate-construction failures leave prior state untouched. No counter wraps or
saturates.

`flush(completedBefore:)` returns immutable `InputAggregate` values only for whole periods whose end
is at or before the cutoff. All aggregates are constructed before any bucket is removed. The cutoff
then seals those periods: repeating the same flush returns no values, and a late sample cannot
recreate an already flushed hour. A partially elapsed hour remains open even when the cutoff falls
inside it.

## Alternatives considered

- **Expose a public raw-event protocol:** rejected because other modules could serialize, log, or
  retain replayable samples before privacy coarsening.
- **Use a lock-protected class:** possible, but a Swift actor gives one auditable owner under Swift 6
  and avoids exposing synchronous mutation across executors.
- **Use UTC epoch-hour division:** rejected because it hides repeated/gap civil-hour semantics from
  users and downstream day rollups.
- **Flush the current partial hour:** rejected because later events could create a second aggregate
  for the same period and make persistence idempotency ambiguous.
- **Store pointer location per application:** rejected because it joins context with fine-grained
  behavior and exceeds the ADR 0006 totals-only application contract.
- **Saturate counters on overflow:** rejected because it silently turns corrupted totals into
  plausible-looking observations.

## Privacy and security impact

There is no typed text, key order, exact pointer coordinate, pointer path, bundle identifier, title,
URL, or document content in a public or persistable accumulator type. Transient raw values exist only
for the duration of an actor call. Suppressed inputs do not create empty evidence of application,
display, or time activity. Flushed values are revalidated by the closed Core aggregate initializer.

## Migration and rollout

This slice adds no persistence schema and does not start a collector. Any pre-release test data
created with direct Foundation calendar-hour intervals must be discarded or migrated because those
intervals can overlap in sub-hour DST zones. A later CGEventTap adapter must
remain inside `DaydayCapture`, pass every sample through the privacy disposition gate, and never add
Codable or logging conformance to transient samples. Storage may accept only flushed
`InputAggregate` values. Changing grid size, integer units, raw/public visibility, or sealing
semantics requires another privacy review and ADR update.

## Consequences

- Platform input adapters can coarsen concurrently delivered samples without sharing mutable state.
- DST, hour boundaries, topology changes, and application switches retain objective semantics.
- Late or overflowing input fails closed and can be surfaced as a collector health event later.
- Permission requests, CGEventTap lifecycle, durable storage, UI, and retention remain separate
  follow-up slices.
