# ADR 0017: Fail-closed CGEventTap input adapter

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

ADR 0006 and ADR 0011 close the persistent input contract and the in-memory coarsening boundary.
The real macOS adapter must now observe keyboard and pointer events without turning the application
into a keylogger or an interaction-replay store. It must also stop promptly when Input Monitoring
is unavailable, secure input begins, the user pauses or disables collection, the GUI session is
unavailable, or the foreground application is excluded or uncertain.

`CGEventTap` can be disabled by the system after a timeout or by user input. Blind immediate restart
loops would consume resources and repeatedly touch a privacy-sensitive platform capability. Multi-
display pointer positions also need an already-reconciled opaque display identity; a runtime display
number is not a durable identity.

## Decision

`DaydayCapture` owns a listen-only `CGEventTap` at the session boundary. The platform callback
extracts only these module-internal, non-Codable transient facts:

- non-repeat key-down time and the `UInt16` physical hardware key code;
- pointer movement or button-down time and one transient global point;
- scroll time, point, and signed integer axis deltas; or
- a closed authorization, secure-input, or tap-disabled boundary.

The callback never reads a character, keyboard layout output, modifier flags, pasteboard content,
event source process, or free-form platform error. Physical keys are sent to the accumulator with a
nil application identifier, so no key-to-application join is produced. Auto-repeat events are
excluded from physical actuation counts.

Before extracting an event, the production backend rechecks non-prompting Input Monitoring and
`IsSecureEventInputEnabled`. The actor coordinator rechecks those facts and the latest product gate
again before mutation. The product gate requires at least one independently enabled, authorized,
and unpaused keyboard/pointer collector, an available user session, and an explicitly allowed
foreground privacy state. Unknown is denied. Closing the gate stops the tap and invalidates its
session generation, so late callbacks contribute nothing.

Pointer points are immediately resolved against injected, already-reconciled display regions and
normalized into the accumulator grid. Zero or multiple matching regions fail closed, including
ambiguous mirrored bounds. Only one previous pointer sample is kept in volatile actor state to
derive total distance and at most five seconds of coarse-cell dwell. It is cleared at every stop and
is never returned, serialized, logged, or stored. Click, scroll, distance, and dwell contributions
carry no application identifier and become only the existing per-display aggregate totals.

The tap's admitted lifetime becomes exclusion-adjusted aggregate coverage. It is split by the
existing accumulator at canonical civil-hour boundaries. Failed aggregate validation stops the
collector with a closed diagnostic reason rather than dropping an error into a log.

Tap disablement and backend creation failure use the finite delay sequence 250 ms, 500 ms, 1 s,
2 s, and 4 s. After five failed attempts the adapter remains unavailable until an explicit product-
gate update or start request. Authorization loss never auto-prompts or auto-retries. Secure input is
rechecked with the same sequence and then at the capped four-second interval, because ordinary
password entry may outlast one backoff window; collection remains stopped until secure input ends.

The production backend is actor-isolated to the main run loop because a Core Foundation event-tap
source must have a stable run-loop owner. Tests inject an async backend, display regions, probes,
and clock, and therefore never create a real event tap or trigger TCC.

## Alternatives considered

- **Persist raw events and aggregate later:** rejected because it enables typed-text and pointer-
  path replay.
- **Publish a raw-event protocol from Capture:** rejected because another module could log or
  serialize it before coarsening.
- **Associate key codes with the foreground application:** rejected because the per-key/per-app
  matrix materially increases typing inference risk.
- **Record all auto-repeat key-downs:** rejected because the contract describes physical key
  actuations, not OS repeat emissions.
- **Guess between overlapping displays:** rejected because a heat-map cell would be attached to a
  false display identity.
- **Restart forever at a fixed interval:** rejected because failure must be bounded and visible.

## Privacy and security impact

Characters, text, key order, modifier combinations, exact pointer history, application linkage,
passwords, and secure-input events are absent from every public and persistent type. One exact point
and one key identity exist only transiently inside Capture until the accumulator actor call. Secure
input, exclusions, pause/disable, session loss, and TCC loss contribute zero events after their gate
is observed. The event tap uses `.listenOnly` and cannot modify user input.

The remaining integration obligation is ordering the foreground privacy-state update before
admitting a new application's input. Application composition must derive that closed state from the
mandatory application-window gate and update this coordinator on every lifecycle and consent
transition.

## Migration and rollout

This adapter introduces no new persisted schema. Existing pre-release input aggregates remain valid.
Production composition must supply current reconciled display regions and the two collector states;
it must not substitute bundle identifiers, titles, URLs, or raw application metadata into this
adapter. A real-Mac smoke test is still required for TCC grant/revocation, secure input, sleep/session
boundaries, multiple displays, and system tap disablement before v0.1 acceptance.

## Consequences

- Keyboard and pointer totals can be collected with standard macOS APIs and no third-party runtime.
- The backend can recover from transient tap disablement without an unbounded retry loop.
- Ambiguous or unsafe contexts trade a small amount of missing objective data for a hard privacy
  boundary.
- Dwell is a bounded pointer-position observation, not a focus, attention, or productivity score.
