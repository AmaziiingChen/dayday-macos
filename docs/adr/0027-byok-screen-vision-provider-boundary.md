# ADR 0027: Screen visual inference uses a separate BYOK provider boundary

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Local Apple Vision OCR can recover visible text, but text alone cannot reliably distinguish
reading, writing, navigation, development, communication, or media use. The configured DeepSeek
work-report model is a text-only provider and must not silently receive screenshot payloads.

## Decision

`DaydayAI` owns a purpose-specific OpenAI-compatible visual-inference client that is independent
from work-report generation. Its input is a non-Codable, bounded, already-redacted compressed image
derivative plus optional bounded OCR lines. It rejects original-resolution images, unsupported
media types, empty data, oversized payloads, and invalid dimensions before a network request exists.

The provider must return one strict JSON object containing a short summary, an objective description
of the visible interaction, a coarse activity kind, confidence, and bounded evidence phrases. The
client validates both the JSON key set and every field before the result can leave `DaydayAI`.
Provider request IDs and reported token counts are returned for later durable usage accounting;
credentials and response bodies are never retained or logged by this component.

Production composition may upload a derivative only when Capture produced it after
OCR-coordinate redaction, the foreground context passed the secure/incognito safety gate, and all
three distinct visual-provider development settings (`DAYDAY_VISION_ENDPOINT`,
`DAYDAY_VISION_MODEL`, and `DAYDAY_VISION_API_KEY`) are present. Missing visual configuration is a
silent disabled state. A text-only DeepSeek configuration is never used as an image-capable fallback.

## Consequences

- Visual inference can be tested and configured without changing the report prompt or journal
  isolation boundary.
- Provider selection remains replaceable and BYOK; Dayday gains no subscription dependency.
- Capture connects only the bounded derivative value; `CVPixelBuffer` and original screenshot files
  never cross Capture or Core.
- OCR remains an objective observation; this visual result is explicitly an inference and must be
  displayed and persisted as such.
