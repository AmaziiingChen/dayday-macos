# ADR 0036: Visual understanding uses bounded continuous timeline batches

- **Status:** Accepted
- **Date:** 2026-08-08

## Context

The first screen-vision slice sent one 1280px image and its OCR text to the visual provider. It
did not give the provider a temporal sequence or the privacy-filtered foreground application fact.
Visually similar communication applications could therefore be misidentified, and the report later
had to parse a formatted prose observation rather than consume a time-bounded visual inference.

## Decision

The v0.1 runtime keeps source-resolution frames only in memory, runs local OCR/redaction at most
once per display every ten seconds, and emits a redacted derivative up to 1600px and 2 MB. A
derivative is allowed even when OCR finds no text; the local safety gate and redaction still run.

`ScreenVisionRuntime` accumulates at least three and at most eight chronological derivatives into
one bounded provider request. Each image is a separate attachment with its capture time, a
non-identifying display label, and bounded redacted OCR. The request additionally includes the most
recent allowed foreground application label and filtered window title from the local objective
repository. Those system facts are authoritative for application identity: the model may report a
pixel/context conflict, but must not replace them with a guessed product name.

The provider still returns the existing strict inference object. The durable inference observation
uses the first and final frame times as its provenance interval. A multi-display batch has no
invented single-display provenance. The report continues to consume visual material only as an
explicit AI inference with retained observation IDs; DeepSeek remains the final text writer and
never receives screenshots.

## Alternatives

- Keep single-frame calls and refine only the prompt. Rejected because no prompt can reconstruct
  state changes or correct missing system identity.
- Use a remote conversation/cache as the source of continuity. Rejected because provider caches are
  optional, opaque and not a durable local audit trail.
- Persist original 4K screenshots or an always-on recording. Rejected because Dayday requires
  original captures to remain ephemeral.
- Stitch displays into one ultra-wide image. Rejected because it loses per-display provenance and
  reduces small-text readability.

## Privacy impact

Only already-redacted compressed derivatives cross the provider boundary. The batch itself is
non-Codable and has no file-writing API. The local application and window facts were already
privacy-filtered before durable storage; their inclusion is bounded and only occurs for an allowed
visual request. No raw screenshots, typed text, key order, mouse-event history, credentials,
incognito context, or model conversation state is retained.

## Migration impact

No SQLite migration is needed. Existing inference records remain readable. New records use
collector version `byok-screen-vision-timeline-v1`, payload schema version 2, and may carry an
`endedAt` value in their existing provenance payload.

## Consequences

- Visual requests are fewer but contain temporal and system context, improving the evidence
  available for a work-intent inference.
- The v0.1 flushes when three frames are available; a timer-based partial-window flush and
  event-specific frame selection remain follow-up work.
- The 1600px full-frame derivative is an improvement over 1280px, but OCR-selected high-resolution
  crops remain a separate follow-up slice.
- Dayflow's fixed-commit source was inspected for the general batch/timelapse approach; this ADR's
  implementation is independent and copies no Dayflow code.
