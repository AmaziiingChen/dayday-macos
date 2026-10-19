# ADR 0015: Capture-owned screen consent runtime

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

ADR 0009 separates explicit product consent from macOS TCC authorization, while ADR 0010 makes
screen frames ephemeral and requires a single-use authorization for every ScreenCaptureKit start.
The first stream slice exposed its consent lease, authorization gate, token, and tokenized `start`
outside `DaydayCapture`. That made the unit boundary testable, but it also allowed application
composition to become the effective owner of a live collection capability. It did not provide one
place that actively stopped capture when product consent, TCC authorization, the target display, or
the graphical session changed while a stream was already running.

## Decision

`ScreenCaptureConsentRuntime` is the only public production entry point that can cause screen
capture to start. It owns exactly one `ScreenCaptureConsentLease`, its non-prompting authorization
gate, the single-use capabilities issued by that gate, the volatile display target, and one
`ScreenCaptureStream`. The lease, gate, start token, gate decision, and tokenized stream `start`
are Capture-internal.

The App may publish only these objective inputs:

- a validated, already-saved `screenUnderstanding` `CollectorConsent`;
- the current reconciled display target or its removal;
- whether the graphical session and screens are available; and
- a request to refresh the non-prompting TCC fact or shut down.

The runtime never imports or accepts `PermissionRequesting`, a prompt adapter, or a closure that can
request access. User-initiated prompting remains in the explicit onboarding path defined by ADR
0009. App composition forwards only successful screen-consent transitions; other collectors do not
reach the runtime. `SystemLifecycleBridge` forwards objective user-session, screen-wake, and system
sleep state. The runtime starts fail closed until both session dimensions have been observed as
available.

App's synchronous consent and lifecycle callbacks pass through one MainActor task chain before
crossing to the runtime actor. This preserves delivery order, so a stale enable or wake cannot
overtake a later pause, disable, sleep, or session-loss fact.

Positive reconciliation is scheduled only after the runtime actor records the newest fact; it
never keeps the App delivery chain waiting on ScreenCaptureKit. Negative consent and session facts
can therefore invalidate the revision and lease while an older backend start remains suspended.
On application termination, `applicationShouldTerminate` defers process exit until composition
detaches permission and lifecycle sources, closes the relay, and awaits runtime shutdown.

While consent, a target, and the session remain available, Capture performs a one-second
non-prompting screen-recording preflight. Revocation immediately invalidates the active stream. A
later authorized result may recover with a newly issued single-use token; an old token is never
reused.

Every desired-state mutation advances a revision before awaiting the stream/backend. Pause,
disable, consent loss, target removal, session loss, TCC loss, and shutdown invalidate the active
stream generation before the asynchronous backend stop. If a previous start finishes afterward,
the stream generation and live lease revalidation prevent it from publishing `available` or
delivering frames. Shutdown cancels authorization monitoring before stopping and is idempotent.

## Alternatives considered

- **Let App own the lease and gate:** rejected because the application layer could retain or issue
  collection capability independently of Capture lifecycle enforcement.
- **Pass a boolean or validator closure into every start:** rejected because callers could inject an
  always-true validator and because a point-in-time boolean cannot observe later consent changes.
- **Stop only when the next frame arrives:** rejected because revoked collection could remain active
  indefinitely on a static screen.
- **Rely only on foreground refresh from App:** rejected because TCC can change while the process is
  active; Capture must actively revalidate without prompting.
- **Automatically call the macOS request API:** rejected because background, launch, resume, and
  collector reconciliation must remain prompt-inert.
- **Expose the raw ScreenCaptureKit stream as the production coordinator:** rejected because raw
  backend lifecycle does not encode product consent or graphical-session availability.

## Privacy and security impact

The change reduces capability exposure: neither App nor Integrations can construct a lease, issue a
token, substitute authorization policy, or invoke tokenized start. Pause, disable, TCC revocation,
session loss, target removal, and teardown all stop raw frame delivery at the Capture boundary.
Only the existing sanitized availability facts and objective frame metadata leave Capture; original
frames stay ephemeral under ADR 0010.

The authorization monitor uses `CGPreflightScreenCaptureAccess` through
`MacOSCaptureAuthorizationPreflight`; it never invokes `CGRequestScreenCaptureAccess` and does not
display UI. No new persistence, logging, telemetry, network access, or free-form error surface is
introduced.

## Migration impact

This is a pre-release source compatibility change. Callers of
`ScreenCaptureStream.start(display:authorization:)` must migrate to objective
`ScreenCaptureConsentRuntime` updates. The lease, token, gate, and gate decision are no longer
public API. No persisted schema or user data changes.

Any future change that makes tokens reusable, exposes the lease outside Capture, adds a prompt seam
to the runtime, weakens active revocation, or changes the one-runtime/one-lease ownership model
requires a new ADR and security review.

## Rollout

1. Land the runtime, access-control narrowing, race tests, and App consent/lifecycle forwarding.
2. Connect reconciled display targets in the display-orchestration slice.
3. Connect sanitized frame metadata to Understanding only after privacy filtering is complete.
4. Verify TCC grant, revocation, sleep, fast-user-switch, and display replacement in a signed local
   app bundle before v0.1 acceptance.

## Consequences

- App composition sees one prompt-inert objective runtime instead of capture capabilities.
- Product and platform revocation actively cut the stream, including while backend start is in
  flight.
- A low-frequency preflight task exists only while consent, target, and session are all eligible.
- Reconnection requires a fresh token and can recover silently after the user changes System
  Settings.
- Real-device lifecycle and TCC behavior still require app-bundle acceptance testing.
