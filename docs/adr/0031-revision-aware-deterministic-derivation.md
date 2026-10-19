# ADR 0031: Revision-aware deterministic derivation

## Context

An in-progress logical day can be derived more than once. A later `asOf` can extend an open
Session while retaining its earlier objective-event membership. Reusing the revision-1 identifier
would therefore try to replace an immutable deterministic result.

## Decision

`ObjectiveUnderstandingPipeline.derive` accepts a target derivation revision and an optional
previous complete snapshot. Revision 1 remains the default convenience call and requires no prior
snapshot. Every later revision requires a nonempty snapshot whose Session and Activity members all
carry exactly the immediately preceding revision. Deterministic Session and Activity identifiers
include the target revision, so a later rebuild cannot reuse an immutable identifier with different
interval bounds.

A Session receives a predecessor only when exactly one prior Session has the same display and
start, and its ordered objective-event membership is a prefix of the new membership. An Activity
receives a predecessor only when every member Session establishes a predecessor and exactly one
prior Activity has that ordered member list. No match is guessed across lanes.

A later revision may contain a newly appearing Activity with no predecessor. `ActivityLineage`
therefore requires a positive revision and still rejects a revision-1 predecessor and
self-supersession, but no longer treats a missing predecessor in a later revision as invalid.

## Privacy impact

This changes only deterministic IDs and opaque lineage identifiers. It adds no content, model,
Journal, Mood, OCR, screenshot, or input-event data.

## Migration impact

None in this slice. Persistence and atomic revision selection are intentionally deferred to the
following storage slice.

## Alternatives

- Reuse an ID when membership is unchanged: rejected because a later end time would mutate an
  immutable Session.
- Infer predecessors from overlap alone: rejected because concurrent or repeated lanes would make
  lineage ambiguous.
- Require every later Activity to have a predecessor: rejected because a new lane can first appear
  in a later in-progress rebuild.
