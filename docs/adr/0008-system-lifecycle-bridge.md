# ADR 0008: Main-actor system lifecycle bridge

- Status: Accepted
- Date: 2026-08-01

## Context

The pure `CollectorCoordinator` already models independent application-wide
suppression reasons, but it deliberately owns no platform services. The macOS
composition needs to translate objective workspace lifecycle notifications
into those existing state-machine commands without requesting permissions or
mixing platform callbacks with collection logic.

Notification delivery also needs deterministic tests. Directly coupling the
coordinator to the shared `NSWorkspace.notificationCenter` would make observer
lifetime, cancellation, and duplicate delivery difficult to verify.

## Decision

`DaydayCapture` defines an injectable `SystemLifecycleNotificationSource` that
delivers six objective facts through a cancellable observation:

| NSWorkspace notification | Lifecycle fact | Coordinator command |
| --- | --- | --- |
| `willSleepNotification` | system will sleep | `setSystemSleeping(true)` |
| `didWakeNotification` | system did wake | `setSystemSleeping(false)` |
| `sessionDidResignActiveNotification` | GUI user session switched out/inactive | `setUserSessionActive(false)` |
| `sessionDidBecomeActiveNotification` | GUI user session switched in/active | `setUserSessionActive(true)` |
| `screensDidSleepNotification` | displays slept | `setScreensAwake(false)` |
| `screensDidWakeNotification` | displays woke | `setScreensAwake(true)` |

The production source observes `NSWorkspace.shared.notificationCenter` on the
main queue. Before `start()` returns it also reads initial availability from the
public `CGSessionCopyCurrentDictionary` keys `kCGSessionOnConsoleKey` and
`kCGSessionLoginDoneKey`, plus `CGGetOnlineDisplayList` and `CGDisplayIsAsleep`
for every online display. Missing session state, an off-console/incomplete login,
no online display, a display-list error, or all online displays asleep fails
closed. The bridge installs observers before taking
this snapshot so a later queued notification reconciles any concurrent change.

`SystemLifecycleBridge`, its source, observation, and event handler
are all `@MainActor`; the bridge owns its `CollectorCoordinator` value and
provides `mutateCoordinator` so application commands use the same serialized
owner.

`start()` and `teardown()` are idempotent. Teardown removes every notification
observer, and the production observation also removes remaining observers when
released. A per-registration identity rejects delivery that was already queued
when teardown occurred. Duplicate lifecycle facts are intentionally forwarded
to the coordinator, whose committed idempotency semantics produce an
observable no-op transition rather than inventing another boundary.

The bridge records the latest transition or typed coordinator error and offers
callbacks for composition code that needs to consume Session boundaries or
surface a failure. No notification content is captured or persisted.

## Alternatives considered

- Put `NSWorkspace` observers directly in the SwiftUI app. Rejected because it
  couples collection correctness to view lifetime and makes teardown fragile.
- Make `CollectorCoordinator` itself observe notifications. Rejected because
  the core coordinator must remain a pure, platform-independent state machine.
- Deliver on arbitrary queues and protect mutation with locks. Rejected because
  workspace lifecycle is low-frequency and main-actor serialization is simpler
  and auditable.

## Privacy and security impact

Only boolean lifecycle facts are handled. The bridge requests no permission,
takes no screenshot, reads no window or input content, performs no network I/O,
and persists nothing. System, session, and screen availability facts only
suppress collection.

## Migration and rollout

This adds platform adapters and two new version-one pause-reason enum values;
there is no released persistence schema to migrate. The application composition
root can create one bridge, start it after
constructing the coordinator, and call teardown during application shutdown or
replacement. Tests inject an isolated notification source or notification
center and verify mapping, duplicate delivery, cancellation, and restart.

## Consequences

- Collector lifecycle mutation is serialized and independently testable.
- Session-boundary consumers can observe the exact coordinator transition.
- NSWorkspace session activity means only that a GUI login session switched in
  or out. It is never named or presented as lock/unlock.
- `screensDidSleep` is an independent availability boundary; it does not imply
  system sleep or an explicit lock.
- macOS exposes no supported NSWorkspace notification for an immediate ordinary
  Lock Screen transition. This slice therefore does not claim to detect lock.
  Screen capture is suppressed using the supported generic system/session/screen
  facts above. `SCFrameStatus.blank` and `.suspended` are not lock signals and
  must never be mapped to one. Dedicated lock detection and recovery remain an
  external actual-Mac research and smoke-test gate; any future implementation
  requires a supported public signal and a follow-up ADR.
