# ADR 0047: Owner-configurable work-report pipeline and durable source references

## Status

Accepted.

## Context

The private owner build had a useful work-report editor and a closed `WorkReportContext` type, but
the runtime pipeline was less explicit than the product contract. The Today timeline and report
page were incorrectly described as waiting to be linked even though their independence is
intentional. Calendar, reminder, todo and weather values were permitted by the Core allowlist, yet
only Activities, visual summaries and one transient work note reached production generation. The
note IDs retained by revisions could not be resolved later. Work start, work end, report generation
time and the logical-day boundary were also not exposed as one owner-visible policy. Finally, the
exact model messages were code-only behavior rather than an inspectable product setting.

## Decision

- Today and Work Report remain separate sibling surfaces. They share the logical-day boundary but
  neither embeds or depends on the other.
- `DailyWorkSchedule` owns four validated local values: work start (09:00), work end (18:00), report
  generation (18:00), and logical-day boundary hour (04:00). Settings persist and publish one
  validated schedule snapshot. The scheduler checks every minute and never overrides a report,
  final version or uncommitted working copy.
- The current production report projection is deliberately narrower than the long-lived Core
  allowlist: durable H2 Activities, objective application/window segments, visual segments, an
  explicit report-page work note, and an optional current-logical-day district weather snapshot.
  Objective application segments retain H1 event lineage and do not fabricate a display identity
  or masquerade as H2 Activities. Calendar, reminders and confirmed todos remain valid contract
  fields but are not populated in this phase.
- Prompt version `work-report-v6` uses separate `system` and `user` messages. Owner-editable task
  and output instructions live inside the system message, followed by fixed fact, privacy,
  uncertainty, authoritative-time and prompt-injection boundaries. Result-like claims supported
  only by visible UI or model output remain attributed rather than independently verified. The
  user message contains the only admissible `WorkReportContext` JSON inside an explicitly
  untrusted data delimiter.
- Generation compares objective-text and visual-inference watermarks. When objective visible
  content is more than five minutes ahead, no provider call is made and the scheduler retries as
  the local pipeline catches up. New EventID or visual ObservationID references may append a model
  revision to an untouched AI draft after the evidence stream has been quiet for ten minutes,
  preventing per-minute regeneration during continued work. User revisions, working copies and
  final reports are never overwritten.
- The upstream screen-vision client keeps its closed response schema and bounds every generated
  prose field before persistence. Display labels may be deterministically reconciled only when
  response cardinality matches unique displays or submitted frames. A partial or single combined
  state set for multiple displays is retained only as explicitly uncertain, unknown-role
  observations with capped confidence; an empty set or ambiguous extra states still fail. Rejected evidence remains in the
  crash-safe replay queue, and diagnostics log validation stages rather than provider response text.
  Runtime batching enforces both the four-time-slice and eight-frame request ceilings, splitting
  dense four-display windows before provider invocation rather than retrying an invalid local batch.
- Report-only visual context groups compatible observations across five-minute gaps, limits each
  group to thirty minutes, bounds detailed evidence and submits at most 36 chronological segments
  while retaining the first and last. Today uses the same readable grouping window without
  changing the durable archive.
- Production objective storage supplies bounded batch reads for application-context projections;
  report assembly does not issue one SQLite query and actor hop per event. Scalar reads remain the
  compatibility path for small repositories and tests.
- Work-report requests preserve the configured endpoint and model, disable deep thinking and cap
  report output at 4096 tokens. Settings preview serializes this exact task-specific request.
- Settings display and edit the task/output instructions and generate a credential-free in-memory
  preview of the exact system message, user message, context JSON and serialized request body.
  Preview never calls the provider and is not persisted or logged.
- `WorkReportGenerationRepository.saveGenerated` commits a generated revision together with its
  `PersistedWorkReportNote` and `WeatherSnapshot` source bodies. SQLite work-report schema v2 adds
  dedicated source tables and indexes. Reference-set equality and day ownership are validated
  before the transaction; objective application EventIDs must resolve to admitted application
  context rows in the same owner database. ID conflicts or report failures roll back the whole write.
- Weather is an objective environment fact only. Runtime conversion requires the observation to
  fall in the report's logical day and emits only a district display label and opaque stable key;
  coordinates and placemark objects never cross into Core report context.

## Privacy impact

The report allowlist is not widened to journal or mood data. Editable instructions cannot change
the application-level source projection and are followed by fixed system guardrails. Request
preview contains real work context and therefore remains transient in memory. Credentials remain
in the credential store and Authorization header only. Durable retention increases only by the
explicit report work-note copy and the already-allowed objective district weather snapshot needed
to resolve revision lineage. Application/window labels already admitted by the objective and
visible-content collectors, including group names, contact names and visible conversation text,
receive no additional report-layer filtering by owner decision.

## Migration impact

Fresh databases are created at work-report schema version 2 with migration journal entries 1 and
2. A validated version-1 database creates the two source tables and indexes, appends migration 2,
and updates its fingerprint in one transaction. Existing reports and revisions are retained.
Historical revisions whose old transient note IDs were never stored cannot be reconstructed; the
integrity guarantee applies to new `saveGenerated` writes.

## Alternatives

- Merge the Today timeline into the report page: rejected because the two surfaces serve different
  reading and writing jobs and their independence is intentional.
- Populate every type permitted by `WorkReportContext`: rejected for this phase because calendar,
  reminder and todo access depends on external environment and consent work not required for the
  current report-quality milestone.
- Make the entire system message editable: rejected because product-enforced data and privacy
  boundaries must not depend on owner-authored prompt text.
- Persist full prompts or previews for audit: rejected because source references, prompt version
  and model provenance provide the required lineage without retaining another copy of work data.
