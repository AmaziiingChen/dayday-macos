# ADR 0032: Atomic deterministic understanding rebuild storage

## Context

Sessions and provisional Activities are immutable deterministic interpretations, but an
in-progress 04:00-bounded workday can be rebuilt at a later revision. Saving the two batch types
through independent transactions can leave an incomplete revision after a crash.

## Decision

`PersistedUnderstandingDerivation` is the Core-only envelope for one `DayDescriptor`, revision,
nonempty Session batch, and nonempty deterministic provisional Activity batch. Its validation
requires identical day/revision and requires every Activity Session member to be in that exact
Session batch. `UnderstandingDerivationRepository` saves it atomically and reads the latest
complete validated revision.

SQLite persists the exact Session batch identity in `h2_activity_batches.session_batch_id`. Unique
logical-date/time-zone/bounds/revision keys prevent two incompatible rebuilds from winning the
same revision. A read validates envelopes, ordered member IDs, payload-normalized values, and
cross-batch membership before returning data. No incomplete revision is returned.

## Privacy impact

The envelope contains only existing Session and deterministic provisional Activity records and
opaque identifiers. It has no Journal, Mood, model, OCR, screenshot, raw input, or provider path.

## Migration impact

Existing Session v3 gains a unique logical-day revision index. Activity v1 batches are rebuilt to
carry the exact Session batch foreign key only when every old Activity batch resolves to exactly
one existing Session batch; ambiguous or incomplete rows fail closed without writes.

## Alternatives

- Save Session then Activity independently: rejected because crashes create partial revisions.
- Infer an Activity's Session batch from its day at read time: rejected because a day has multiple
  revisions and inference can relabel conflicting history.
