# ADR 0023: HealthKit background observation for the companion queue

- **Status:** Proposed
- **Date:** 2026-08-01

## Context

The companion can manually read and queue incremental HealthKit changes, but Apple Watch and
Health app updates should not require a person to remember to open the companion. iOS does not
permit an app to run continuously in the background, so this feature must treat background delivery
as an opportunity to reconcile a durable local queue, not as a real-time guarantee.

## Decision

For the four initial sample kinds, the companion registers `HKObserverQuery` instances and requests
HealthKit background delivery after an authorization request succeeds. On a delivered update it
starts the same anchored reconciliation path as the manual action, persists the queue transaction,
then advances anchors and completes the HealthKit callback. The app registers observers again at
launch. It shows the last observed state and local record/tombstone counts in the companion UI.

This does not create a background network service or trigger LAN transfer. If iOS does not launch
or schedule the app, the next foreground/manual reconciliation catches up from the persisted anchor.

## Privacy impact

No extra health types, data fields, remote endpoints, or third parties are introduced. Observer
notifications contain no health payloads in app logs; facts remain in the protected local queue.

## Consequences

- Companion behavior becomes eventually current without promising a fixed delay.
- Real-device testing must cover locked device, delayed HealthKit writes, authorization change,
  force-quit, and later foreground recovery.
