# ADR 0001: Native, local-first macOS architecture

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday must run continuously with low resource use, integrate deeply with macOS permissions and
events, remain useful offline, avoid subscription infrastructure, and preserve private user data.
The first user works on Apple Silicon macOS; Windows and mobile are future possibilities rather than
v0.1 constraints.

## Decision

- Build v0.1 in Swift and SwiftUI for macOS 14 or later, Apple Silicon first.
- Ship one application process with a menu-bar popover, normal application window, and background
  actors. Closing the window does not stop capture.
- Store domain data and evidence locally. Store credentials in Keychain. Do not add remote
  telemetry, a required account, cloud storage, or a subscription dependency.
- Use BYOK provider adapters behind Core protocols. Local capture and objective persistence continue
  when AI/network work is unavailable or over budget.
- Keep platform-neutral domain semantics in DaydayCore, while macOS-specific services live in
  Capture, Integrations, Storage, and App modules.
- Use a localhost-only authenticated API/MCP facade for external Agents; do not expose LAN mode in
  v0.1.

## Alternatives considered

- **Electron/web UI:** faster cross-platform reuse, but weaker native integration and a larger
  continuous-runtime footprint for the first platform.
- **Rust core plus Swift shell:** attractive for future Windows reuse, but adds FFI and delivery risk
  before domain contracts are stable.
- **Cloud-first service/account:** simplifies synchronization and remote processing, but contradicts
  local-first privacy, cost, and offline goals.
- **Separate helper daemon immediately:** stronger process isolation, but adds installation,
  lifecycle, and debugging complexity before demonstrated need.

## Privacy impact

Positive: user data stays on the Mac by default; network access is limited to explicit providers;
credentials receive Keychain protection; no telemetry/account service observes usage. FileVault is
the v0.1 at-rest assumption for the local database and evidence, which does not defend against
malware executing as the same user.

## Migration impact

Public shared types remain platform-neutral enough for a future Windows collector or mobile capture
client to produce compatible records. Adding another platform must not move AppKit/ScreenCaptureKit
types into Core. A future daemon split should preserve repository/service protocols and require its
own ADR and migration plan.

## Consequences

- The product can exercise native permissions, ScreenCaptureKit, Accessibility, EventKit, and
  Keychain directly with predictable UX and performance.
- Cross-platform work is deferred; reuse initially occurs at domain/protocol and persisted-format
  levels rather than UI/runtime levels.
- Provider and storage replacements are explicit composition-root choices.
- Public distribution signing/notarization cost is deferred until public beta; local Xcode builds
  and an unpacked Chrome extension support v0.1 development.
