# ADR 0006: Privacy-closed input aggregate contract

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday needs long-running keyboard and pointer statistics without building a replayable input log.
The collection layer observes short-lived hardware events, while Core and Storage must only see
coarse hour/day summaries. A generic event payload, ordered samples, exact coordinates, or a
per-key-per-application matrix could reconstruct typed or interaction context and is therefore
outside the product's privacy boundary.

Hour buckets also have to survive civil-time edge cases, display topology changes, collector
upgrades, arithmetic overflow, and eventual 180-day compaction. Compaction must not silently
delete source data before a daily replacement is durable.

## Decision

`InputAggregate` is a closed, versioned value for one hour or one workday bucket. Its period stores
finite UTC start/end instants, an IANA time-zone identifier, and granularity. Hour periods use a
canonical, disjoint partition of the local civil day. The partition sorts and deduplicates nominal
wall-clock hour starts, the next civil-day start, and every actual time-zone offset transition in
that day, then uses adjacent instants as bucket boundaries. This matters in zones such as
Australia/Lord_Howe, where Foundation's calendar-hour intervals overlap during a 30-minute DST
change. Canonical buckets may therefore be shorter or longer than 60 minutes, but they never
overlap and cover the civil day exactly once. Day periods also retain the configured
workday-boundary hour rather than
inferring it from a DST-shifted instant. They end at that boundary on the next civil day using
`WorkdayBoundary` gap/repeat semantics, allowing non-24-hour daylight-saving days, including
23.5- and 24.5-hour days.

The contract contains only:

- unordered counts keyed by `UInt16` physical hardware key code;
- per-application total key count and total pointer values, keyed only by an opaque UUID resolved
  through a separately governed application catalog, with no physical-key or grid detail;
- left, right, and other click totals;
- non-negative up/down/left/right scroll magnitudes and estimated pointer distance in integer
  milli-points;
- per-display, per-topology-revision pointer totals and a bounded normalized grid of click totals
  and dwell milliseconds;
- exclusion-adjusted included duration; and
- canonical sets of collector and keyboard-layout versions.

The normalized grid is capped at 128 rows and columns. It stores cell indices rather than exact
coordinates. Display identity always combines opaque `DisplayID` with topology revision, so data
from a changed layout is never silently overlaid.

`InputAggregationPolicy` merges already-coarsened aggregates only. Integer arithmetic is checked;
overflow fails the operation rather than wrapping or saturating. Collection dispositions other
than `allowed` return the existing accumulator unchanged, producing zero counts and zero included
duration. Canonical sorting and integer units make same-bucket merges deterministic and
associative for valid, non-overflowing inputs.

Hourly retention defaults to 180 local civil days measured from the current workday boundary.
`makeDailyRollup` accepts explicit hour inputs and an explicit daily target, rejects duplicate,
overlapping, out-of-day, and cross-time-zone sources, and returns a `DailyInputRollupPlan`. The plan
contains the new daily value and source hour IDs but performs no persistence or deletion. Storage
must durably commit the daily aggregate before explicitly deleting source hours in its own
transaction/recovery protocol.
The output ID cannot equal a source-hour ID, and callers cannot directly construct an unchecked
rollup plan.

This first slice retains the validated civil period rather than caching a mutable `DayID`. Day
assignment remains an explicit WorkdayBoundary/Day operation, consistent with ObjectiveEvent.
Once the shared Day contract is accepted, persistence may link an aggregate to that Day without
weakening the period or privacy invariants.

## Alternatives considered

- **Persist raw key/pointer events and aggregate in queries:** enables replay, creates needless
  retention risk, and violates the product contract.
- **Store per-key counts per application:** useful for detailed charts but materially increases
  inference risk about what was typed in a specific context.
- **Store exact normalized coordinates with timestamps:** remains a replayable pointer trajectory
  even if absolute display pixels are removed.
- **Use floating-point counters and distances:** makes merge results order-dependent and allows
  non-finite values; fixed integer units are deterministic and checked.
- **Treat every day as 24 absolute hours:** shifts civil boundaries during daylight-saving changes.
- **Use `Calendar.dateInterval(of: .hour)` directly:** those intervals can overlap across sub-hour
  offset changes, causing counts and included duration to be irreversibly double-counted in rollup.
- **Delete source hours inside the Core rollup helper:** couples pure domain policy to storage and
  can lose history if persistence of the replacement fails.
- **Collapse topology revisions for the same display:** produces misleading heat maps after a
  rotation, resolution, or layout change.

## Privacy impact

Typed text, characters, key order, modifier sequences, exact input timestamps, precise pointer
coordinates, pointer paths, and per-key-per-application distributions are unrepresentable in the
contract. Application identifiers are opaque UUIDs rather than bundle IDs, free-form window
titles, URLs, controls, or documents. Excluded, secure-input, locked, incognito,
password-manager, paused,
and otherwise suppressed periods contribute nothing when passed through the policy.

The grid size cap is a defense against repurposing a nominal heat map as a high-resolution position
log. Topology revision separation prevents historical bins from being presented as exact current
screen locations.

## Migration impact

This is schema version one for input aggregates. Pre-release data written with overlapping
calendar-hour semantics must be reset or migrated to the canonical partition before reuse; there is
no released persistence requiring backward compatibility. Storage must encode counts losslessly, preserve
the UTC period and IANA time zone, keep topology revisions distinct, and revalidate Core types on
decode. Hour-to-day compaction needs a recoverable two-phase/transactional implementation that
never deletes hours merely because a plan was constructed.

Future changes to grid resolution limits, integer units, application dimensions, day linkage, or
retention semantics require a follow-up ADR and storage migration. Raw event fields cannot be
introduced as a compatibility shortcut.

## Consequences

- Capture implementations must aggregate in memory and pass only closed bucket deltas to Core.
- Charts retain useful keyboard, click, scroll, distance, and heat-map statistics without input
  replay data.
- Checked arithmetic requires callers to surface or recover from an invalid bucket instead of
  silently corrupting totals.
- Missing hourly buckets may still produce a partial daily rollup; the included duration makes the
  observed coverage explicit without claiming continuous activity.
- Storage work remains necessary for durable rollup transactions, deletion journals, and queries.
