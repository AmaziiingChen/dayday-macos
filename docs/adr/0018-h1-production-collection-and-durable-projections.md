# ADR 0018: H1 production collection and durable projections

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday already has privacy-closed domain values, individual macOS collectors, fail-closed screen
consent handling, and independently versioned SQLite repositories. It does not yet have a
production composition that continuously starts those collectors, persists their useful output,
survives an application restart, or presents a real workday timeline.

H1 must close that local loop without introducing OCR, cloud inference, raw input history, or
persistent full-resolution screenshots. It also has to preserve enough objective application and
window context for later Session and Activity construction. Persisting only a fact that “some
application changed” would satisfy a mechanical storage demo but would not support a useful work
timeline or work report.

This decision accepts the H1 contract proposed as `H1-CONTRACT-01`, with the product-level
amendments confirmed by the user: privacy-filtered window context is durable for ordinary desktop
applications, while structured Chrome context waits for the authenticated extension so incognito
exclusion can be enforced.

## Decision

### Capture-owned production runtime

`DaydayCapture` owns a production `H1CollectionRuntime`. The App composition root opens the
production store and injects typed Core repository ports; Capture does not depend on Storage, and
App does not receive raw frames, AX values, key events, pointer samples, or platform callbacks.

The runtime has the following contract:

- Its control plane is main-actor isolated and owns collector lifecycle, authorization facts,
  topology reconciliation, privacy gates, and collector state publication.
- Durable writes run on a separate serialized actor/lane and cannot block the main actor.
- `start()` and `shutdown()` are non-prompting and idempotent. Closing the main window does not
  shut down collection; application termination awaits shutdown.
- Every enabled collector requires durable product consent, a current non-prompting authorization
  fact when TCC applies, an available user session, and no active pause or privacy boundary.
- Negative facts win every race. Pause, disable, TCC revocation, lock, sleep, secure input,
  exclusion, session loss, display removal, and shutdown invalidate earlier asynchronous starts
  and callbacks before persistence is attempted.
- Display streams are independent. Topology removal stops the affected stream and removes its input
  region before any replacement region or target is published.
- H1 owns screen authorization, display targets, and stream lifecycle, but a production stream is
  demand-driven and must not run merely to discard pixels. It starts only when a privacy-gated
  ephemeral consumer is installed. The consumer is an H2 Capture-to-Understanding boundary and
  never an App/UI API. H1 may use an explicit test sink for real-Mac stream verification, but it
  does not persist frames or emit per-frame Events.

Presentation health is a latest-value state stream and may use `bufferingNewest(1)`. Objective
history is different: application/window changes, lifecycle boundaries, pause and authorization
boundaries, display-topology changes, collector failures, recovery, and finalized input aggregates
must not be coalesced or silently discarded. Only repeated equivalent health/availability
snapshots may be coalesced.

The write lane is bounded and reserves capacity for one critical boundary after ordinary writes
stop being admitted. When a required historical write cannot be queued, the runtime first closes
collector admission at a defined boundary, preserves all data admitted before that boundary, and
uses the reserved capacity for the failure/stop boundary. A negative callback invalidates only
content observed after its boundary; it does not cancel an already-admitted durable write.

When Storage itself is unavailable, the boundary cannot honestly be called durable. The runtime
stops collectors that would produce more durable data and keeps a safe in-memory failure fact. On
explicit recovery, it writes a typed `CollectionGapRecord` before any producer restarts. The gap
uses the last successfully persisted boundary as a conservative start and the recovery time as its
end; it is visibly approximate when the exact failure instant was not durable. If the process also
terminated, the next successful startup derives the same conservative gap from the latest durable
collector/event state. Non-content permission and health monitoring may continue so the UI can
offer a repair path. The runtime never claims continuity across the gap.

Collector state transitions use a typed, versioned record linked to an `ObjectiveEvent`. They do
not use a generic JSON payload. A start, stop, failure, authorization boundary, pause boundary, and
recovery therefore remain reconstructable after restart. The event source collector and the
recorded state's collector kind must be identical; a write with two different collector identities
is not a valid linked record.

### Durable application and window context

An admitted application/window observation is written atomically with its `ObjectiveEvent` as a
typed `ApplicationContextRecord`. Objective namespace version three added event-linked application
context and collector-state projections to the version-two application catalog and identity salt;
version four adds a content-free suppression projection for rejected application-context candidates.
It may persist only:

- the linked `EventID`;
- an opaque, stable `ApplicationIdentifier`;
- a bounded, privacy-filtered application display-label snapshot;
- a bounded, privacy-filtered window-title snapshot;
- a bounded document filename hint, never a complete path or URL; and
- an explicit record/payload version.

Raw bundle identifiers remain Capture-internal and are never stored in an Event, aggregate,
diagnostic log, export, or model request. A versioned installation salt stored with the objective
namespace derives the opaque application identifier from a normalized bundle identifier. Version
one admits at most 255 ASCII bytes from `[A-Za-z0-9.-]`, lowercases them, and hashes the domain tag
`dayday.application-id.v1`, a 32-byte random installation salt, and the normalized bytes with
SHA-256. The first 16 digest bytes form an RFC 9562 version-8 UUID after setting variant/version
bits. The salt never rotates automatically. A future derivation requires a schema migration and
explicit old-to-new aliases. The salt is ordinary local catalog metadata, not a credential, so
rolling backup and restore preserve identity without introducing a second Keychain failure mode.
A derived-ID collision or missing or invalid catalog metadata fails the application identity
projection closed; it never falls back to persisting a raw bundle identifier.

The catalog stores the latest admitted display label. Each event-linked record stores its own label
snapshot so historical presentation does not change when an application is renamed.

An `ApplicationContextRecord` is content-bearing even when every field has already passed its own
bound checks. Its linked event must therefore have an `allowed` security disposition. A
`metadataOnly` or `excluded` event may persist only the safe boundary/suppression fact and can never
be paired with application identity, labels, titles, or filename hints. The event source must be
the application/window-context collector; authenticated Chrome observations use the separate
browser-context event family and a separately reviewed projection.

For ordinary desktop applications, admitted window titles and document filename hints are durable
objective context. In v0.1 they follow objective-event retention and remain until the user clears
or replaces that data; later public settings may add a shorter configurable retention policy.

Chrome is a mandatory special case. A versioned Capture classifier recognizes the supported stable,
Beta, Canary, and Chromium bundle identifiers before identity derivation. H1 application/window
collection persists only their opaque application identity and display label. Chrome title,
domain, path, navigation, switching, and media state become durable only through the authenticated
Chrome bridge after it has established that the context is not incognito. That bridge never stores
query, fragment, page body, forms, or incognito context. An unrecognized browser identity fails
window-content persistence closed until the classifier or a trusted bridge explicitly supports it;
ordinary non-browser Electron applications are not classified as Chrome by engine alone.

Password managers, authentication/login contexts, secure roles, user exclusions, unknown safety
state, and other mandatory exclusions persist only a safe suppression reason. They contain no
application identity, display label, title, document hint, URL, or control value. Accessibility
denial may emit a metadata-only boundary but no window or document content.

### Crash-safe open-hour input checkpoints

Input namespace version two adds `InputAggregateCheckpoint`, a typed repository port, and an
`input_aggregate_open_checkpoints` table. A checkpoint contains a stable aggregate ID, a fully
validated `InputAggregate`, a monotonically increasing revision, and a finite checkpoint time. It
cannot represent characters, key order, modifier sequences, individual timestamps, exact pointer
coordinates, pointer paths, or key/grid-to-application joins.

Capture snapshots an open hour without removing its in-memory bucket. After a bucket first becomes
dirty, the runtime attempts a checkpoint no later than 30 seconds afterward; while new admitted
input continues, it attempts at least once per subsequent 30-second interval. It also forces an
attempt at pause, lock, sleep, secure-input, tap-stop, and orderly-termination boundaries. A
boundary checkpoint may persist data admitted before the boundary; no new input is accumulated
while suppression is active. With healthy Storage, the recovery-point objective is therefore 30
seconds. Storage failure can make the last successful checkpoint older, must stop further input
collection, and must be shown as a gap rather than described as zero loss.

Checkpoint upsert is transactional and revision-aware:

- a higher revision replaces the previous open checkpoint;
- the same revision and canonical payload is idempotent;
- a lower revision, same-revision payload conflict, period mismatch, or invalid payload fails
  closed; and
- retries for one aggregate ID coalesce only to the newest checkpoint, while finalization is never
  discardable.

At an hour boundary, Storage atomically inserts the immutable finalized aggregate and removes its
open checkpoint. Capture removes/seals its memory bucket only after that transaction succeeds. If
the transaction committed but the caller lost its response, retry returns `alreadyFinalized` only
when the exact immutable aggregate exists and the matching checkpoint is absent; every other state
is a conflict. On launch, valid open checkpoints are restored before the input collector starts;
the next revision is the restored revision plus one, and an already-ended checkpoint is finalized
first. No recovered counts may be applied twice. Period construction, time-zone changes, clock
movement, and DST gap/repeat behavior remain governed by ADR 0006 and ADR 0011.

### Durable consent and global collection control

Product consent is distinct from macOS authorization and from application-wide pause. A dedicated
SQLite namespace stores explicit, validated rows rather than Codable blobs:

- per-collector product consent, confirmation time, last action kind, disclosure version, and
  monotonic revision;
- per-collector enabled, disabled, or collector-scoped paused state; and
- one independent global user-pause state.

The persisted action kinds are the closed set `enable`, `disable`, `pause`, and `resume`, with the
same legal transitions as `CollectorConsentStateMachine`. `enable` and `resume` both produce
enabled status but remain distinguishable for audit. The first enable atomically creates the
collector row and its confirmation; there is no separately durable “agreed but not yet enabled”
intermediate state. Compare-and-transition uses the previous revision so concurrent actions cannot
silently overwrite one another.

A missing collector row is a valid new-install state and reads as synthetic `unconfirmed`; it does
not make the store fail to open. Consent namespace migration creates exactly one global-control row
with `isPaused = false`, which is safe because every missing collector row is unconfirmed. A missing
global row after migration, duplicate row, unknown schema version, malformed value, or invalid
state/action combination is corruption and prevents a production store from opening. A
syntactically valid stored disclosure version that differs from the current collector disclosure
is retained for audit but exposed as `renewalRequired` and does not permit collection; malformed
versions fail validation. A historical TCC grant never implies Dayday product consent. TCC
revocation changes current authorization, not the user's product-consent record.

Enable and resume follow this order: explicit user action, successful durable consent/control
write, then—only from the same user-initiated UI path—a TCC request when required. Collection may
start in that interaction only after the request returns an authorized fact; collectors without a
TCC requirement may start after the durable write. Launch, preflight, wake, and automatic recovery
remain non-prompting. Resuming the global pause clears only global pause; it never clears a
collector-scoped pause, disabled consent, privacy boundary, or missing authorization.

Pause and disable first close the relevant in-memory admission gate, then attempt a pre-boundary
input checkpoint, create and synchronize a small owner-only fail-closed marker, commit the durable
negative control, stop/drain the platform backend, and finally remove the marker. The operation is
not reported complete until the durable control and runtime stop have succeeded. The marker belongs
to Storage's secure-location boundary; Capture receives only a typed negative-transition port.

If the marker or control write fails, the current process remains stopped and the UI explicitly
reports that the choice is not durably saved. No automatic recovery occurs in that process. No
software can promise to remember a new choice across process loss when every durable write fails;
the UI and diagnostics must not claim otherwise. On launch, a successfully written unresolved
marker keeps the affected collector or global runtime stopped until the transition is replayed or
the user explicitly resolves it. Production startup also requires a successful Storage writeability
probe before any durable-data producer starts.

Within one running process, a pause or disable boundary retains the occurrence time and time-zone
context captured when the negative hold begins, even when marker or SQLite work completes later.
After a crash, replay must not invent an unavailable historical occurrence time: Capture starts
inert and records the boundary time at which the new runtime observes the persisted stopped gate.
The collector confirmation timestamp remains the audit time of the collector control action; the
version-one global control has no separate original-action timestamp.

A marker/control persistence failure is a recoverable control-plane failure, not proof that the
capture engine itself terminated. The runtime remains held and publishes the failure until an
explicit recovery succeeds. An orderly application shutdown may subsequently finish in a clean
stopped state, while the App continues to own the user-visible explanation and replay/repair path.

The version-one marker is a bounded set with at most one intent per scope and at most
`CollectorKind.allCases.count + 1` intents. Scope is either `global` or one closed `CollectorKind`;
the only global target is paused, and collector targets are paused or disabled. A collector intent
also stores the original validated confirmation time and disclosure version, expected previous
revision, and exact target revision (`expected + 1`) so a crash before the SQLite commit can replay
the same negative user action. Global intents carry the same expected/target revision pair. It
contains no captured content, free-form text, authorization token, or platform permission fact and
receives the same owner-only, no-symlink, no-extended-ACL hardening as the SQLite database.

Replay occurs before any collector admission. If SQLite contains the exact target state at the
recorded target revision, replay is an idempotent success. If it contains the expected prior state
at the expected revision, Storage applies exactly the recorded negative transition. Any other
revision or state is a conflict and remains fail closed. Only after either success does Storage
atomically remove that intent. Concurrent negative actions for different scopes merge through
atomic whole-file replacement; a second action for an unresolved scope is rejected rather than
overwriting its lineage. An unknown marker version or collector, duplicate scope, invalid target,
invalid revision pair, or invalid confirmation fails all durable-data producers closed and leaves
the marker intact for explicit repair.

## Shared contracts and persistence

The accepted H1 implementation may add these narrow Core ports and values:

- `ApplicationCatalogEntry` and `ApplicationContextRecord`;
- `CollectorStateRecord`;
- `CollectionSuppressionRecord` and `CollectionGapRecord`;
- atomic objective-event insertion/fetch APIs for typed linked records;
- `InputAggregateCheckpoint` and `InputAggregateCheckpointRepository`;
- `CollectionConsentRepository` and a typed global collection-control value/repository.

No generic event payload, arbitrary metadata dictionary, raw platform value, or storage-specific
type enters Core.

The existing owner-only `dayday.sqlite3` file may contain three independently versioned
namespaces: objective version four, input aggregate version two, and collection consent/control
version one. `ProductionDataStore.open()` returns no usable store if any required namespace fails
validation. Each migration is retryable and transactional; an interrupted later namespace may
leave an earlier committed migration, but the partially opened composition is never returned.
SQLite durability uses WAL with `synchronous=FULL`; a write is successful only after SQLite reports
the transaction committed. Marker creation/removal uses an atomic same-directory replacement and
explicit file and parent-directory synchronization.

Production startup order is fixed: secure-location and namespace validation; unresolved marker and
consent/control load; open-checkpoint recovery/finalization; non-prompting authorization preflight;
runtime construction; collector admission. A failure in an earlier step prevents later producer
steps but still permits a monitor-only UI model with safe repair information.

## Alternatives considered

- **Persist only context-change envelopes:** rejected because a real day could not be reconstructed
  after restart.
- **Never persist window titles:** rejected for admitted ordinary applications because it removes
  the strongest local task cue and conflicts with the objective work-memory goal.
- **Persist raw AX values and redact later:** rejected because collection would create a sensitive
  archive before the privacy decision.
- **Use raw bundle identifiers as aggregate identities:** rejected because input aggregates require
  an opaque application dimension and raw identifiers needlessly spread platform policy.
- **Use a non-exportable Keychain identity secret:** rejected because losing or failing to restore
  the secret would fragment otherwise valid local history; an installation salt stored with the
  catalog is sufficient for an opaque identifier.
- **Persist Chrome AX window titles before the extension:** rejected because AX cannot reliably
  prove that a Chrome window is not incognito.
- **Persist input only at the end of an hour:** rejected because a crash or ordinary restart could
  lose almost an hour of statistics.
- **Treat global pause as changing every collector's consent:** rejected because temporary runtime
  control and informed product consent are different facts.
- **Let App compose every platform adapter:** rejected because fail-closed ordering, callback
  invalidation, multi-display topology, and storage backpressure would be split across UI code.

## Privacy and security impact

H1 creates durable filtered window context, aggregate input checkpoints, collector-state history,
and consent/control records. It still cannot persist screen pixels, OCR, typed text, key order,
exact pointer history, complete document paths, raw bundle identifiers, Chrome incognito context,
or excluded content. Mandatory exclusions cannot be overridden by a user preference.

All data stays local. H1 performs no model request and exposes no network API. SQLite payloads,
WAL/SHM files, fail-closed markers, exports, and release logs must be inspected by tests for
prohibited fields and representative secrets.

## Migration impact

There is no public release data. Nevertheless, objective and input schema changes are versioned
migrations rather than resets so the implementation exercises the same upgrade path required for
dogfood and future publication. Newer schema versions are rejected by older code. Version-one and
version-two objective databases may already contain application-context or collector-transition
envelopes without linked projections. Migration preserves those legacy facts without inventing
content. After version three, the generic event insertion path rejects new events of either
projection-required kind; version four also rejects every new non-allowed generic event so only the
closed application-context suppression path can persist it. A linked write that encounters a
grandfathered event-only ID is a conflict rather than a projection backfill.

The application-context projection is separate from the volatile
`ApplicationWindowContextFact`; making the source fact bounded and filtered never makes it
implicitly Codable. The persistence gate constructs the explicit Core record after the final
admission decision.

## Rollout

1. Add consent/control Core ports, consent namespace, fail-closed marker, and persistence tests.
2. Add objective version-three application/collector linked records to the version-two catalog and
   atomic migration/rollback/privacy tests.
3. Add input version-two open checkpoints, recovery/finalization, and crash/DST tests.
4. Add the Capture runtime, identity resolver, non-destructive accumulator snapshots, bounded
   writer, and race/backpressure tests.
5. Compose the production store and runtime in App; replace Today/menu preview state with real
   repository projections while retaining explicit Debug sample scenarios.
6. Run a fixed-bundle real-Mac smoke covering explicit TCC prompts, revocation, secure input,
   sleep/lock, relaunch, storage failure, and multiple displays before half-day and two-week
   dogfood gates begin.
