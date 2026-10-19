# Dayday Health Companion

An isolated iPhone companion foundation for the future Dayday health-facts archive.

## Current slice

- Shows whether HealthKit is available on the device.
- Requests read access for a broad, closed non-clinical catalog: heart and respiratory metrics,
  sleep, activity, workouts, body measurements, mobility and running metrics, user-recorded
  nutrition/hydration, and audio exposure. It explicitly excludes clinical records, waveforms,
  routes, and document-like objects.
- Uses anchored HealthKit reads for that catalog, retaining a protected companion-local SQLite
  queue of facts and deletion tombstones. The earlier JSON probe queue migrates locally on first
  use, without uploading its content.
- Registers HealthKit background delivery as an opportunity to reconcile that local queue; iOS
  scheduling remains best effort and is never a real-time guarantee.
- Persists a metadata-only local import/sync plan and shows the user what still awaits Mac/LAN
  integration.
- Lets the user inspect the most recent companion-local facts, including their time, source, and
  objective raw value, before any Mac integration exists.
- Shows per-type reading coverage: a type is either not yet checked, checked with no discovered
  facts, or shown with its factual local count and latest retained timestamp.
- Defines a versioned, test-covered JSON transfer envelope for a future paired local-network
  transport. It does not send or expose that envelope yet.

It deliberately does **not** connect to a Mac, advertise a Bonjour service, use iCloud, or expose
an API/MCP surface. The private queue is not a shared Dayday schema; the distinct future transfer
envelope is specified in ADR 0043. See ADRs 0021/0022 and
`docs/HEALTH_FACTS_LOCAL_SYNC_PLAN.md` in the integration working tree for the broader plan.
See ADR 0041 for the exact catalog and exclusions.

## Local development

```sh
xcodegen generate --spec HealthCompanion/project.yml
xcodebuild -project DaydayHealthCompanion.xcodeproj -scheme DaydayHealthCompanion \
  -destination 'generic/platform=iOS Simulator' build
```

Run on a physical iPhone for HealthKit authorization behavior. The simulator cannot validate the
user's real HealthKit data or background behavior.
