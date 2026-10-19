# ADR 0043: Versioned Companion health-facts transfer envelope

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

The protected iPhone SQLite queue is deliberately an implementation detail. The future paired
Mac must not open, copy, or depend on that database. It needs a separately reviewable factual
payload that can be authenticated and encrypted by a later local-network transport.

## Decision

The Companion defines `HealthFactsTransferEnvelope` format version 1. Each JSON envelope carries a
batch ID, an opaque Companion installation ID, creation time, objective observations, and deletion
tombstones. An observation retains only its stable HealthKit UUID, closed catalog kind, time range,
source provenance, and existing typed raw payload. The envelope rejects duplicate IDs and a fact
plus a tombstone for the same UUID in a single batch.

Dates are encoded as milliseconds since the Unix epoch and JSON keys are sorted. A receiver must
reject an unsupported format version instead of attempting an unsafe best-effort decode.

## Consequences

- The future Mac repository can accept a reviewed wire contract without learning the iPhone queue
  schema or opening its files.
- This decision adds **no** LAN discovery, listener, pairing, encryption, acknowledgement cursor,
  background transfer, iCloud storage, or external disclosure. Those remain a later vertical slice.
- The envelope is a factual transport record, not an analysis contract: it includes no health
  score, inferred state, journal, work-report, mood, clinical, route, or document data.
