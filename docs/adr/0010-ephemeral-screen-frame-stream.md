# ADR 0010: Ephemeral ScreenCaptureKit frame stream

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday needs objective per-display screen observations, but a raw screen frame is among the most
sensitive inputs in the product. ScreenCaptureKit delivers reference-counted `CMSampleBuffer` and
`CVPixelBuffer` objects at a rate that can outrun OCR or other understanding work. Allowing those
objects into Core, Storage, an unbounded task queue, a generic `Data` value, or a temporary file
would create an accidental screenshot archive and make lock/error races privacy-significant.

The capture foundation must also survive displays changing, late callbacks after cancellation,
supported session suppression, stream failure, and explicit restart without claiming that ordinary
Lock Screen detection or lifecycle composition is already complete.

## Decision

`ScreenCaptureStream` is a macOS 14 ScreenCaptureKit adapter for exactly one reconciled display.
Its target combines the active runtime display ID with opaque `DisplayID` and topology revision.
The runtime ID is used only to select `SCDisplay`; public frame metadata carries only the opaque
display context, observation time, and pixel dimensions.

Raw media is module-internal. `CapturedScreenSample` and `EphemeralScreenFrame` are not public,
`Codable`, `Data`, or file-backed values. A trusted DaydayCapture processor may borrow a
`CVPixelBuffer` only through a nonescaping closure and must finish before returning. Public output
is limited to `ObjectiveScreenFrameMetadata` and sanitized availability facts.

The adapter uses two bounded layers: ScreenCaptureKit `queueDepth` is one, and the processing pump
allows one in-flight frame plus one replaceable latest-frame slot. If processing is slow, each new
pending frame releases the previous pending frame. It never grows a frame queue. Stopping capture
invalidates a generation and clears the pending slot; callbacks and processor completion from an
older generation cannot publish metadata.

Start, stop, and same-target start are idempotent. A different target performs stop/restart. A
backend start failure, backend error, backend stop, authorization failure, or generic supported
session suppression stops frame delivery and emits a sanitized hard-unavailable fact. An explicit
later authorized `start` may recover. The public stream API requires a single-use capability from
`ScreenCaptureStartAuthorizationGate`; the gate checks enabled `screenUnderstanding` product
consent through a concrete live lease plus a non-prompting Screen Recording preflight. The
capability rechecks both immediately before and after the asynchronous backend start. A pause,
disable, or TCC revocation during start stops the newly created backend without ever publishing
`available`. It never calls a TCC permission-request API.

The lifecycle hook is intentionally named `suspendForUnavailableSession`. It can consume supported
system/session/screen availability policy but never asserts that the machine locked.
`SCFrameStatus.blank` and `.suspended` are ignored as non-frame availability states and are never
mapped to lock. Dedicated lock detection and recovery remain pending an actual-Mac research and
smoke-test gate using supported public APIs.

The injected processor is synchronous and serialized. It may inspect a raw buffer only through the
nonescaping borrow and must not persist, log, network-send, or independently publish raw or derived
content. Deactivation drops pending work and suppresses the only publication completion, but it
cannot preempt a processor already executing; processors must be bounded and return promptly.

## Alternatives considered

- **Publish raw buffers to other modules:** makes raw-frame lifetime and retention unenforceable.
- **Convert every frame to image `Data`:** creates a copy that can be trivially logged or persisted.
- **Write temporary screenshots for OCR:** leaves recoverable sensitive material and adds cleanup
  failure modes.
- **Spawn one task per frame:** slow processing creates unbounded memory and stale-frame latency.
- **Keep only the first pending frame:** preserves stale work while discarding more relevant recent
  context.
- **Treat errors as ordinary idle state:** hides a hard observation gap from downstream composition.

## Privacy impact

Original frame surfaces live only in reference-counted Capture memory while queued or synchronously
processed. At most one frame is processed and one latest frame is pending. No public type exposes a
raw media object, serialization conformance, file URL, error description, window title, OCR text,
or generic payload. Authorization and unavailable-session states invalidate delivery before their
hard-unavailable facts are emitted.

The start capability enforces live product consent and current TCC preflight. The application must
still separately establish exclusions, secure-input policy, and lifecycle composition. Production
composition is gated on routing every persisted screen-consent transition through the same lease
and stopping an already-active stream on later policy or consent revocation; this slice is not yet
wired into the App composition root. Lease construction and mutation are module-internal, so live
App composition is fail-closed until that Capture-owned runtime exists.

## Migration impact

There is no persistence migration because neither raw frames nor these volatile outputs are stored.
If evidence frames are later retained, they require a separate Core contract, retention policy,
capacity limit, redaction policy, schema migration, and ADR. Exposing raw media outside
DaydayCapture or changing the bounded queue policy also requires a follow-up ADR.

## Rollout

1. Land the injectable stream and fake-backend tests without UI or storage wiring.
2. Compose supported system/session/screen suppression and consent changes with the collector
   coordinator in an owned follow-up.
3. Add a privacy-reviewed ephemeral understanding processor.
4. Design retained compressed evidence separately; never reuse the raw-frame wrapper as storage.
