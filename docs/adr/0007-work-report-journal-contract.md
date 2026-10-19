# ADR 0007: Work-report, journal, mood, weather, and safe-context contracts

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

ADR 0003 establishes that professional work reports and personal journals are independent sibling
artifacts. That policy now needs enforceable Core types before storage, model adapters, or UI code
can accidentally collapse them into one daily document or pass private writing into a work-report
request. Logical-day identity must also remain stable across time-zone and workday-boundary changes.

The contract must preserve exact user wording, retain report revisions, allow optional AI assistance
without overwriting authoritative text, support city-level weather and user-authored mood, and keep
the default work-report body free-form. It must not implement persistence, provider calls, or UI.

## Decision

### Day identity

`DayID` is an opaque UUID-backed identity. `DayDescriptor` separately freezes the logical Gregorian
date, IANA time-zone identifier, configured boundary hour, and absolute start/end instants. The
descriptor validates that its start is the configured local hour on the logical date and its end is
the next civil-day boundary. This preserves 23/25-hour daylight-saving days without encoding
mutable civil-time policy into the identifier.
Boundary calculation anchors to the requested civil date itself, not local noon, so configured
hours `13...23` cannot be mistaken for the preceding logical day. Nonexistent times advance to the
first valid local time and repeated times use their first occurrence through `WorkdayBoundary`.

### Work reports and revisions

`WorkReport` points to one accepted `WorkReportRevision`. Revisions are immutable, numbered records
with explicit lineage, origin, optional model provenance, safe source references, and free-form
body. There is no default visible template contract. A draft may accept an automatic replacement;
after the user finalizes a report, automatic replacement fails closed. A new candidate remains an
independent revision until explicit user acceptance, and a user-accepted update to a final report
remains final.
The report retains both current revision ID and number. Initial revisions are exactly number one;
each accepted replacement is exactly current number plus one, points to the current ID, and cannot
self-reference. Journal originals enforce the equivalent version-chain invariants. Decoding runs
the same validation and cannot introduce a non-positive current number.

### Journal authority and AI copies

`JournalEntry` points only to `JournalOriginalVersionID`. `JournalOriginalVersion` stores exact
user-authored text without trimming, correction, or normalization and advances through explicit
user-edit lineage. `JournalDerivedVersion` uses a different, non-interchangeable identifier and
records its source original, requested operation, output body, model, provider, prompt version, and
time. No Core operation can make a derived identifier the entry's current original. Fragments are
private user-authored records and have no work-context representation.

V0.1 `JournalAttachmentPayload` is a closed sum of a relative-file-key image and an HTTP(S) link.
Image keys are storage-generated, normalized ASCII POSIX-style relative keys that also reject
Windows drive/backslash forms and control characters. Image media is a closed raster set (JPEG,
PNG, HEIC, and WebP), and positive byte and pixel counts are required. The payload cannot represent
SVG, audio, video, generic files, or machine-specific absolute image paths.

### Mood and weather

`MoodEntry` has a source enum whose only V0.1 value is `user`. Pleasantness and energy are distinct
validated `MoodLevel` values on the integer scale `1...5`; integers avoid floating-point ambiguity
and false precision across storage and platforms. Mood can be recorded repeatedly, scoped, labeled,
given a user reason, and marked as an overall feeling. No inference/model source exists.

`WeatherSnapshot` contains provider-attributed objective observations for `CityWeatherLocation`.
The location uses an opaque UUID, a bounded single-line locality label, a bounded provider mapping
key, and an IANA time zone. Coordinate-like, address-like, multiline, control-bearing, and unbounded
labels are rejected; there is no latitude, longitude, address, or movement-history field.
Measurements are validated for finiteness and physical bounds. Weather is optional objective
environment context only; the contract provides no field for emotion, mood causation, diagnosis,
or weather-derived affect.

### Work-report context allowlist

`WorkReportContext` is the sole work-generation/export envelope. Its stored properties are a
closed allowlist:

- logical day descriptor;
- Activity summaries and objective evidence identifiers;
- user-authored work notes;
- explicitly allowed work-calendar summaries and reminders;
- confirmed todos; and
- same-day objective weather snapshots.

Each input has a purpose-specific Core DTO. There is no generic payload, dictionary, arbitrary
codable input, or initializer/conversion for personal entries, fragments, attachments, derived
copies, or mood. `WorkReportSourceReferences` retains only work-safe opaque identifiers for audit
lineage. The projection DTOs are `Encodable`, not generally `Decodable`: repository code must
construct them through their validated, purpose-specific initializers instead of converting an
untrusted generic payload. Provider adapters and external work-context APIs must accept this typed
envelope rather than a broad Day/database object.

The context initializer is also its integrity boundary. IDs are unique by artifact type, evidence
frame IDs are unique across activities, and note/todo activity references must resolve inside the
same context. Point observations use the half-open logical-day interval `[start, end)`; activity and
calendar intervals must be non-empty (`start < end`) and overlap it. Weather must both carry the context DayID and have a same-day
observation time. Reminder and confirmed-todo timestamps included in a daily context must be in the
same half-open interval.

## Alternatives considered

- **Date/time-zone encoded DayID:** deterministic-looking, but makes identity depend on policy and
  complicates boundary migrations. An opaque ID plus immutable descriptor is safer.
- **One mutable report row:** simpler storage, but automatic generation can silently destroy a
  confirmed report. Immutable revisions and explicit acceptance preserve history.
- **One mutable journal body plus AI edits:** convenient, but destroys the user's exact subjective
  wording. Separate original and derived types make overwrite mistakes harder to express.
- **Generic daily context with prompt exclusions:** flexible, but private data could leave the
  process before a prompt instruction is applied. A closed work allowlist enforces the boundary at
  compile and serialization time.
- **Continuous mood values:** visually smooth, but encode false precision and create cross-platform
  comparison ambiguity. A five-level integer value is sufficient for V0.1.
- **Weather-to-mood interpretation:** potentially engaging, but unsupported causal inference and a
  violation of the objective/subjective boundary. Trends may place records side by side without
  asserting causation.

## Privacy impact

The highest-risk private types cannot inhabit the work-generation envelope or its source-reference
record. User journal text stays exact and model output is visibly separate. Mood cannot be inferred
or supplied to report generation. Images use normalized relative keys and closed raster media; web
links exclude local file URLs. City-level weather uses opaque identity and catalog mapping rather
than precise or continuous location storage. Codable validation is a
required follow-up concern for each persistence adapter and untrusted import boundary; storage must
not bypass these Core initializers.

## Migration impact

This is the first persisted-contract spine for these records; no released schema exists yet.
Development data written before this revision is incompatible: work reports add
`currentRevisionNumber`, journal entries add `currentOriginalVersionNumber`, image key/media fields
become closed value types, and city locations replace a free-form identifier with opaque ID plus a
provider mapping key. Development storage must migrate these values from validated related rows or
reset pre-release fixtures; it must not invent lineage numbers or reinterpret arbitrary location
text. Storage should
normalize immutable versions and preserve opaque UUIDs, explicit enum strings, logical-day boundary
snapshots, and source-reference arrays under a versioned migration. It may store both artifact
families in one database, but repository projections must remain separate. Changing the mood scale,
allowlist membership, attachment kinds, day identity, or automatic-acceptance rules requires a new
ADR and migration/API review.

## Rollout plan

1. Land Core types and isolation/validation tests without storage or model behavior.
2. Add separate repositories and migrations for work artifacts, personal artifacts, mood, and
   weather; implement a dedicated work-safe projection.
3. Require text-provider and localhost work-context adapters to accept only `WorkReportContext`.
4. Add UI flows for exact original editing, derived-copy comparison, explicit finalization, and
   city/mood entry without changing the isolation boundary.

## Consequences

- Callers must assemble a deliberate work projection instead of handing a provider an entire Day.
- Report and original-journal histories use more records, but user data cannot be silently replaced.
- Calendar/reminder filtering remains the projection builder's responsibility; only explicitly
  allowed summaries may be constructed.
- Weather may appear beside work or personal artifacts while remaining objective and non-causal.
