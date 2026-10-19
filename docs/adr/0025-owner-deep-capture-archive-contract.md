# ADR 0025: Owner Deep Capture archive contract

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

ADR 0024 permits bounded, redacted visible content and totals-only text-production facts for the
owner-operated private build. They are more sensitive than ordinary objective events and cannot be
added as generic event payloads or broaden existing input aggregates.

## Decision

Create a separate `deep_capture_*` SQLite namespace at schema version 1. It has closed Core
records and repository ports for `VisibleContentObservation` and `TextProductionAggregate`; it is
not a WorkReportContext dependency. Records preserve collector/version/schema source, observation
interval/time zone, opaque application identity, bounded window label, and display topology.

Visible records declare objective text versus inference, source classification, and redaction
state. Text is limited to 32 KiB. Inferences require a stable local origin identifier; objective
text cannot claim one. Exclusions are durable, content-free envelopes containing only safe
provenance and a suppression reason: no text, derived text hash, classification, metric, or
window/document label.

Text production persists only inserted/deleted grapheme totals, inserted scalar total, estimated
word total, correction total, and up to sixteen non-overlapping coarse intervals. It has no
characters, keys, event timestamps, ordering, snapshots, clipboard, or content-derived hashes.
An excluded aggregate must be entirely zero.

The SQLite migration journal and schema fingerprint fail closed on unexpected/tampered schemas.
Newer schemas refuse to open; v1 files reopen exactly. Retention/capacity orchestration and all
collectors remain future work; this slice performs no collection, OCR, UI, AI, or app wiring.

## Alternatives considered

- Add visible text to `ObjectiveEvent`: rejected because that envelope is deliberately payload-free.
- Add text counts to `InputAggregate`: rejected because it would broaden an established
  privacy-closed aggregate and blur its no-content contract.
- Store exclusions nowhere: rejected because negative controls must be testable and auditable.

## Privacy, migration, and rollout impact

The archive is local-only and physically/logically namespaced. Its repository has no implicit
work-report access path, preserving report/journal isolation. Secure input, credentials,
incognito, lock/login, and other hard exclusions persist no content or production signal.
Migration is additive: existing objective and input databases are untouched. Future retention,
export, provider access, and collector integration must explicitly use this archive and retain
these negative tests.
