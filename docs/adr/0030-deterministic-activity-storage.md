# ADR 0030: Deterministic provisional Activity storage

## Context

H2 needs durable, rebuildable Activity interpretations without treating them as objective facts or allowing a model, Journal, Mood, OCR, screenshots, or provider input into the persistence path.

## Decision

`ActivityDerivationBatch` and `ActivityRepository` accept only Activities for one 04:00-bounded `DayDescriptor` and one deterministic revision. Every member must be a deterministic-rule interpretation with low confidence, `needsReview`, and no evidence reference. SQLite stores a canonical logical-day batch envelope plus ordered membership with foreign keys to persisted `h2_sessions`. Exact replay verifies the envelope and every Activity; partial or altered replay conflicts without writes.

The dedicated `h2_activity_*` namespace is fingerprinted and fails closed on missing, extra, renamed, replaced, or altered objects. Direct and production first opens use process-local serialization. No model call occurs in this slice.

## Migration impact

This is schema version 1. No prior Activity schema is migrated or synthesized.
