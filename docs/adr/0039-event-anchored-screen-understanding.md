# ADR 0039: Event anchors request the next safe multi-display observation

- **Status:** Accepted
- **Date:** 2026-08-08

## Context

The bounded visual timeline in ADR 0036 and ADR 0037 has a periodic fallback, but a fixed cadence
can miss the transition immediately after a foreground-application change or after the owner
submits visible text. The resulting batch may contain enough pixels to describe a screen but not
enough temporal context to distinguish, for example, a WeChat reply from a visually similar
conversation surface in another application.

## Decision

Dayday adds ephemeral **observation anchors**. An allowed foreground-application context change,
or a non-repeating Return/Enter physical-key press inside the already-authorized aggregate-only
input collector, asks every active display stream to process its next safe frame without waiting
for the normal OCR cadence. Repeated requests coalesce to one pending anchor per display. The
existing local safety gate, credential redaction, fingerprint comparison, derivative byte limit,
and generation invalidation remain mandatory; an anchor cannot force a frame across any of those
boundaries.

The input collector exposes only a no-payload submission callback. Hardware key codes, key order,
text, modifier state, and timestamps do not leave Capture. An anchor is not proof that a message
was sent or work was completed; it is only a request to make the nearby visible state available
for the normal visual inference pipeline.

`ScreenVisionRuntime` keeps a small in-memory trace of the latest anchor, request completion, and
deterministic segment transition. App composition asks it to inspect the objective repository only
when H1 publishes a new durable history revision, avoiding a recurring database poll. It also gives each provider request up to three bounded recent
visual-segment summaries as explicitly provisional continuity context. The model must treat that
context as a disambiguation hint, never as evidence that overrides the current images or the
authoritative system foreground-app fact. A local deterministic state machine labels each newly
archived inference as a new, continued, changed, or uncertain visible segment for diagnostics.
None of this trace is persisted as an objective event.

## Alternatives

- Capture an always-on video clip around every key press. Rejected: it creates a substantially
  broader raw-media retention and upload surface without being necessary for the P0 feedback loop.
- Persist a model chat/session and rely on provider-side cache. Rejected: cache behavior is opaque,
  provider-specific, and does not make a local report trace auditable.
- Treat Return as a message-send fact. Rejected: Return has application-specific meanings and
  cannot establish a completed action from an input signal alone.

## Privacy impact

The new signal remains content-free and transient. It cannot bypass secure-input, application,
browser, redaction, consent, lifecycle, or authorization gates. No raw screenshots, original
frames, typed text, raw key events, event order, or exact pointer history are stored by this
decision. The visual provider continues to receive only the existing bounded redacted derivatives
and bounded visual-model summaries.

## Migration impact

No storage migration is needed. The trace and state machine are in-memory; existing inference
records and their report lineage remain unchanged.

## Consequences

- A real screen transition is normally available to the provider shortly after a meaningful local
  anchor, while unchanged screens still deduplicate through the existing fingerprint.
- The Settings diagnostics can expose that the pipeline observed an anchor and whether it opened,
  continued, changed, or could not confidently classify a segment.
- The next evaluation slice can use these traces to compare prompt and batching changes against
  known multi-display and chat-composer cases without introducing a remote state dependency.
