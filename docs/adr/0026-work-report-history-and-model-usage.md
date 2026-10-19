# ADR 0026: Work-report history and model-usage persistence

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Dayday can now derive a work-safe `WorkReportContext` and obtain a free-form DeepSeek draft, but
the result exists only in memory. A usable personal build must survive restart, support history and
regeneration, retain immutable revision lineage, and account for provider usage without allowing
journal or mood data into the report path.

## Decision

Add a Core-owned `ModelUsage` record and a `WorkReportRepository` port. `ModelUsage` records the
purpose, provider/model, optional provider request identifier, attempt interval, outcome and
provider-reported prompt/output/cache/total tokens. A successful usage record links to exactly one
work-report revision; failed attempts may remain unlinked for a later attempt-log slice.

`PersistedWorkReportRecord` is the closed atomic unit: the validated `DayDescriptor`, one
`WorkReport`, its accepted current `WorkReportRevision`, and the optional usage linked to that
revision. Retaining the descriptor preserves the configured 04:00 workday and time zone for
history instead of guessing a civil date from generation time. The repository saves
an initial draft or the next accepted revision atomically, enforces one report per `DayID`, rejects
forked/skipped lineage, and returns current records by day or newest-first history.

Until Day descriptors have their own durable catalog, the App derives an application-defined UUID
v8 `DayID` from logical date, IANA time zone and boundary hour. Repeated generation and process
restarts therefore address the same logical workday without treating the civil midnight as a day
boundary.

Implement the port in a separate versioned `work_artifact_*` SQLite namespace in the existing
owner-only production database. Store canonical Codable payloads alongside indexed identity,
lineage and time columns; decode and cross-check every payload against those columns. Schema
metadata, migration journal and fingerprints fail closed on modification or newer versions.

The first App integration automatically accepts regenerated revisions only while the report is a
draft, exactly as ADR 0007 permits. Generated text remains visibly an AI draft. History reads the
same repository. Editing, finalization, Markdown export, failed-attempt accounting and pricing
snapshots remain later slices.

## Alternatives considered

- Keep the latest draft in `UserDefaults`: rejected because it cannot provide atomic revision and
  usage lineage and is not an artifact store.
- Store provider usage inside the report body or model provenance: rejected because accounting is
  structured data and must not contaminate user-visible prose.
- Save a new unrelated report on every generation: rejected because it loses explicit revision
  lineage and makes one workday ambiguous.

## Privacy impact

Only the already-closed `WorkReportContext` can reach the provider. Persisted reports contain work
prose, work-safe source identifiers and provider accounting; no journal, mood, credential,
reasoning content or raw request/response body is stored. API keys remain in Keychain.

## Migration and rollout impact

This is additive schema version 1 under the `work_artifact_*` prefix; existing objective, input and
deep-capture namespaces are unchanged. `ProductionDataStore.open()` must open and validate the new
repository before returning. Pre-release databases gain the namespace transactionally. The App
first wires save/current/history, then later adds editing/finalization/export and complete failed
attempt/pricing accounting.

## Consequences

- A successful generated draft and its usage are recoverable after restart.
- Regeneration cannot silently fork or replace a finalized report.
- History can show real local reports without sample data.
- Provider pricing and failed billable attempts still require a follow-up extension of
  `ModelUsage`; the schema must migrate rather than reinterpret V1 records.
