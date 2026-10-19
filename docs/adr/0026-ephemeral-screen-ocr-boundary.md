# ADR 0026: Ephemeral screen OCR crosses Capture only as redacted text

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Dayday already owns a bounded ScreenCaptureKit frame lane and a dedicated Owner Deep Capture
archive, but the production stream discarded the image surface after emitting metadata. The first
usable screen-understanding slice needs local OCR without exposing a serializable raw-image API or
conflating OCR text with visual-model inference.

## Decision

`DaydayCapture` performs Apple Vision text recognition while the frame's `CVPixelBuffer` is borrowed
inside the existing ephemeral processing lane. Before anything crosses the module boundary it:

- rate-limits work and suppresses unchanged frames using a non-persisted image fingerprint;
- fails closed before OCR when secure input is active, Accessibility cannot prove the focused
  control safe, or the foreground application is an authentication/password surface;
- removes credential- and authentication-like lines;
- enforces the existing `RedactedOCRLine` and line-count bounds; and
- releases the raw surface without writing image bytes to disk.

Capture may emit an objective screen-text output containing frame metadata, bounded redacted lines,
and whether redaction removed content. It may also emit a non-Codable, bounded JPEG derivative made
inside the same borrowed-frame call: maximum edge 1280 pixels, credential OCR bounds covered, and no
file location or original-resolution bytes. Generation gating remains authoritative: a result
computed for a stopped or replaced stream is not delivered. Application code must consume the JPEG
transiently and may not archive it as deep-capture text or an original screenshot.

Application composition converts this safe output into an objective `VisibleContentObservation`
and writes it to the dedicated deep-capture archive. OCR text is not an Activity conclusion and is
not automatically made available to WorkReport generation.

Visual semantic understanding remains a separate BYOK provider stage. A visual model may receive
the downscaled and redacted derivative only through ADR 0027's distinct configuration, credential,
usage, and network-transfer contract. DeepSeek's text-only report provider is not used as an image
decoder.

The first production target is the main display selected from the volatile CoreGraphics inventory.
Multi-display fan-out remains a follow-up because the current consent runtime owns one stream.
Chrome is also denied at this gate until its authenticated bridge can prove a non-incognito
context; window titles or pixel appearance are not sufficient proof.

## Alternatives considered

- **Expose `CVPixelBuffer` or `CMSampleBuffer` publicly:** rejected because it creates an
  unbounded raw-media capability outside Capture and weakens stop-generation guarantees.
- **Persist screenshots and OCR them later:** rejected because original-resolution screenshots
  must remain ephemeral and queued files would outlive pause, lock, or shutdown boundaries.
- **Send every frame directly to a visual model:** rejected because it is expensive, duplicates
  unchanged screens, and introduces a network transfer before local classification and redaction.
- **Treat DeepSeek report generation as OCR:** rejected because the configured DeepSeek text model
  accepts text context, not screenshot pixels.

## Privacy, migration, and rollout impact

The SQLite schema does not change; production composition now opens the existing
`deep_capture_*` v1 namespace. Credential-like lines are discarded rather than masked into a
partially reconstructable value. Raw image bytes, JPEG derivatives, and transient fingerprints are
never persisted.
This slice is locally testable with an injected recognizer; real recognition and TCC behavior still
require a signed Debug application smoke test on the owner's Mac.
