# ADR 0019: H2 privacy-safe evidence, sessions, and activities

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

H1 establishes the production collection runtime and durable, objective projections. H2
must turn only privacy-admitted observations into locally reviewable evidence and a
rebuildable understanding of work, without exposing raw screen media beyond
`DaydayCapture` or conflating objective observations with model conclusions.

This decision consolidates H2-CONTRACT-01 and H2-VISION-SEAM-01. It is a semantic
and boundary decision only: it does not add a schema, a package target, a source API,
or an implementation.

## Existing contracts consumed

H2 consumes, rather than redefines, the following accepted contracts:

- H1's objective `ApplicationContextRecord`, `CollectorStateRecord`,
  `CollectionSuppressionRecord`, `CollectionGapRecord`, and persisted closed
  objective events.
- Core identifiers and values including `EventID`, `DisplayID`,
  `ApplicationIdentifier`, `DayID`, `ActivityID`, and `EvidenceFrameID`.
- The existing closed `ObjectiveEventKind.stableStateObservation` kind.
- `WorkReportContext`, `WorkReportActivityContext`, `WorkReport`,
  `WorkReportRevision`, and `WorkReportSourceReferences`.
- The report and journal isolation decisions already recorded by the applicable ADRs.

H2 must not duplicate these contracts, add a generic metadata dictionary or payload,
or reinterpret an existing objective event as a generic stable-state stream.

## Decision

### Capture owns the raw-media boundary

Option A is accepted. `DaydayCapture` keeps raw `CapturedScreenSample`,
`EphemeralScreenFrame`, and the underlying pixel buffer module-internal as required by
ADR 0010. A Capture-owned, bounded privacy/vision processor is the only code that may
borrow a raw frame. It owns, in this order as applicable:

1. privacy admission and mandatory exclusion;
2. bounded OCR and secret detection;
3. redaction of all permitted derivatives;
4. raw-frame deduplication and evidence selection; and
5. safe derivative encoding and preparation of a sanitized candidate.

Only a closed, typed sanitized candidate may cross to `DaydayUnderstanding`. It
contains no raw pixel buffer, original-resolution frame, public raw-media handle, or
unbounded Vision/OCR response. The relay is bounded and obeys the current frame pump's
one-in-flight/latest-pending backpressure, cancellation, and generation-revocation
rules. A candidate that loses its generation or privacy authorization is dropped before
delivery and must leave no derivative.

There is no public raw-buffer borrowing API, no temporary original-frame file, and no
provider or other network call in the Capture path. Capture does not persist raw
media, log sensitive OCR/secret content, or independently publish a derivative.

Option B, a narrow public nonescaping raw-buffer borrow into Understanding, is
rejected. Swift visibility and a nonescaping closure do not sufficiently prove that
borrowed media cannot be transformed, retained asynchronously, persisted, or sent over
the network by a second module.

Option C, a dedicated internal `DaydayVision` target, remains the fallback. It may be
adopted by a later ADR if stronger isolation, a separately auditable native vision
implementation, or Windows portability warrants the package and migration cost. Until
then, it does not exist and raw frames remain Capture-internal.

### Selected evidence is an atomic, exceptional observation

`ObjectiveEventKind.stableStateObservation` is the sole existing event kind that
anchors a selected evidence frame. It is not emitted for every input frame. Capture
emits it only after privacy admission and only when the sanitized derivative is selected
for retention. H2 persists the selected `EvidenceFrame` and its anchoring event
atomically, or persists neither. The event contains no pixels, OCR text, hash, or file
key. Unselected, duplicate, excluded, uncertain, revoked, or failed candidates create
no evidence frame, OCR artifact, or stable-state observation.

An `EvidenceFrame` is a persisted redacted, compressed derivative identified by the
existing `EvidenceFrameID`, with closed provenance to its anchoring event and objective
context. A bounded redaction-passed `OCRArtifact` may be retained only as a child of
that evidence; it is not a raw Vision response and may not outlive its evidence.

Normal evidence derivatives follow the product's seven-day and capacity-bounded
retention policy. Explicit user pinning and a small Activity representative-thumbnail
policy are distinct retention paths; they remain redacted and compressed and never
store original frames. Encoding quality, capacity, thumbnail count, and the exact OCR
bound are deliberately unresolved product constants, not H2 API defaults.

### H2 uses four distinct meaning layers

H2 stores and presents closed typed values with explicit provenance:

- **Objective facts** are only persisted objective events, H1 application/collector/
  suppression/gap records, and selected evidence or its bounded OCR artifact.
- **Deterministic derivations** are reproducible rules over those facts, including
  deduplication, Session construction, and rule-based Activity assembly.
- **Model inferences** are separately typed Activity conclusions with their source
  references, rationale, and a coarse operational confidence band. They are review and
  debug information, calm and collapsed by default in the Evidence Thread. The band
  cannot copy a model's self-reported confidence; calibration inputs and rules require
  a later narrow contract.
- **User corrections** and user-authored work notes are separately typed authorship.
  A work note may support a conclusion, but is never recast as an objective observation.

No layer creates a productivity, focus, absence, or equivalent score.

### Sessions are deterministic single-display lanes

A Session is one objective contiguous context lane on exactly one `DisplayID`. It is
derived deterministically from H1 context and selected evidence facts. It cannot span,
stitch, or silently hand off between displays.

Hard global boundaries end every affected lane and are never bridged: lock, sleep,
global pause, privacy suppression, authorization loss, and every
`CollectionGapRecord`. Display removal ends only the lane for that display. Application
or window context changes are lane-context boundaries; they do not themselves assert an
Activity. H2 does not infer idle time from hourly aggregates or invent an unrecorded
boundary.

An Activity may group independently derived Sessions from one or more displays, but it
does not merge their evidence images or turn them into one continuous Session. A gap is
evidence of unknown continuity, never a reason to stitch an Activity or Session across
it.

### Corrections retain immutable lineage

User corrections are append-only, closed operations over durable Session and event
membership: title/summary/project/category/tag edits and explicit grouping, splitting,
or merging of Session membership. They are anchored to durable facts and Sessions, not
to a transient inferred Activity identifier. Rebuild produces a new superseding
derivation/correction lineage; prior derivations and corrections remain auditable.
Conflicts or ambiguity remain `needsReview` rather than being silently resolved.

### Work reports remain an H3 concern

H2 may populate the existing `WorkReportActivityContext` only through the existing
`WorkReportContext` envelope. That envelope remains the sole report input boundary and
strictly excludes Journal text, mood records, and every other personal artifact. Journal
continues as a separately user-authored, independently timed sibling artifact.

Provider selection, BYOK credentials, explicit network authorization, scheduled report
execution, jobs, retries, pricing/budget accounting, and report revision persistence are
H3 concerns governed by ADR 0007 and the architecture. H3 may consume only persisted,
redacted H2 derivatives; it must never receive raw Capture media. This ADR introduces no
H3 shared types or provider behavior.

## Minimal missing contract families

After reusing the existing contracts above, future H2 work needs only closed families
for:

- persisted `EvidenceFrame` provenance and bounded `OCRArtifact` ownership;
- `ObservationFact`, deterministic derivation provenance, and typed model inference;
- `Session` plus its new `SessionID`, single-display membership, boundaries, and
  supersession lineage;
- the persisted Activity record using the existing `ActivityID`, with grouped Session
  membership and review-only inference details;
- append-only correction operations and their supersession relationships; and
- typed H2 repository ports for day-scoped H1 input queries, atomic selected-evidence
  writes, and persistence reads.

The exact safe-candidate type and relay ownership are part of the first H2 implementation
contract. It must remain closed and contain only sanitized values. No generic payload,
raw-media capability, or DaydayCore change is authorized by this ADR alone.

## Privacy and security impact

- Raw screen frames, raw OCR/Vision output, secrets, and original-resolution captures
  remain ephemeral inside Capture. They cannot be public, serialized, logged, stored,
  or networked.
- Mandatory privacy exclusions and revocation win over evidence selection. On failure or
  uncertainty, H2 retains nothing.
- Persisted evidence, pinned evidence, representative thumbnails, and OCR are always
  redacted derivatives subject to their own retention/capacity policies.
- Evidence Thread presentation must be calm by default. Provenance, rationale, OCR, and
  inference detail are only revealed through deliberate review/debug expansion.
- Report isolation is testable at the `WorkReportContext` serialization/input boundary;
  H2 provides no alternate path around it.

## Migration impact

There is no migration in this ADR. Before any H2 durable write is enabled, a separately
reviewed Core/schema change must add the closed tables, identifiers, constraints,
retention cleanup, atomic selected-evidence/event transaction, and migration tests.
Existing H1 objective projections remain source facts and are never rewritten. Rebuilds
create superseding H2 derivations rather than mutating historical facts or corrections.

## Rollout and test gates

H2 is released in narrow, ordered slices. Each slice requires its listed gate before the
next slice may begin.

1. **Contracts and persistence.** Add the minimal closed H2 types, repository ports,
   schema, atomic write, and cleanup only under an explicit follow-up contract.
   Gate: migration/reopen tests; exact source-reference integrity; no generic payloads.
2. **Capture privacy relay.** Add the Capture-internal processor and bounded sanitized
   relay under a Capture-owned implementation assignment.
   Gate: static visibility tests for no public raw type; no temporary original; no raw
   `Data`/file/network/log path; one-in-flight/latest-pending behavior; cancellation and
   generation-revocation drops; mandatory exclusion and secret-redaction tests.
3. **Evidence vertical slice.** Persist selected redacted evidence and bounded OCR with
   the atomic `stableStateObservation` anchor.
   Gate: selection-only event creation; all-or-nothing event/evidence writes; duplicate,
   excluded, uncertain, failed, and revoked candidates retain nothing; retention,
   capacity, pinning, and thumbnail-policy tests.
4. **Deterministic Sessions.** Derive and rebuild per-display Sessions from H1 facts.
   Gate: multi-display lane separation; every hard gap ends a lane; display removal is
   local; no bridging across gaps; repeatable rebuild fixtures including clock/day edges.
5. **Activities and corrections.** Add cross-display Activity grouping, reviewable
   inferences, and immutable correction/supersession lineage.
   Gate: Activity grouping never changes Session continuity; inference does not create a
   score or copy model confidence; correction/rebuild determinism and `needsReview`
   conflict fixtures.
6. **Report compatibility.** Populate only the existing report context boundary.
   Gate: adversarial Journal/mood/personal-artifact sentinels cannot enter
   `WorkReportContext`; H3 provider tests remain separate.

The implementation must also retain macOS integration tests appropriate to each slice
and portable deterministic fixtures for future Windows implementations. A later H3
release owns provider and scheduled-report acceptance tests.

## Consequences

H2 gains an enforceable privacy boundary without premature cross-module raw-media APIs.
It deliberately leaves compression settings, retention capacities, representative
thumbnail count, OCR limits, and confidence calibration open for product-specific,
narrow follow-up decisions. Option C remains available if the Capture-owned processor
proves insufficiently isolated; Option B remains rejected unless a future ADR can show a
strictly stronger enforceable boundary.
