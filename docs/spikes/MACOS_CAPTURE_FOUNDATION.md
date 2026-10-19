# macOS Capture Foundation Spike

## Scope

This slice establishes metadata-only platform facts for later capture work. It does not start a
ScreenCaptureKit stream, request a frame, install keyboard or pointer event taps, persist an image,
or present a macOS permission prompt.

Implemented surfaces:

- non-prompting Screen Recording and Accessibility authorization preflight;
- online-display metadata enumeration with CoreGraphics;
- normalized, order-independent display-topology value semantics and a deterministic change token;
- protocols around platform calls so later coordinators and tests do not depend directly on global
  macOS functions.

These are `DaydayCapture` platform values. They intentionally do not duplicate Core `Event`,
`Session`, evidence, or permission-policy semantics. A later vertical slice should map them only
after the corresponding Core handoff is accepted.

## API choices and limits

### Permission preflight

`CGPreflightScreenCaptureAccess()` checks whether the current process already has Screen Recording
authorization. It does not request authorization. `AXIsProcessTrusted()` similarly checks whether
the process is trusted for Accessibility without passing the prompt option.

The implementation does **not** call:

- `CGRequestScreenCaptureAccess()`;
- `AXIsProcessTrustedWithOptions(...)` with the prompt key;
- any ScreenCaptureKit API that might enumerate windows or obtain content.

The preflight result is deliberately only `authorized` or `notAuthorized`. Apple's preflight does
not reliably distinguish “not yet requested” from “denied,” so the UI must not claim that it does.
Requesting access remains an explicit onboarding action owned by the app layer.

### Display inventory

`CGGetOnlineDisplayList` reports displays considered online by WindowServer. For each result this
slice reads only:

- runtime display ID;
- logical global bounds;
- current mode pixel dimensions when available, otherwise an explicit unknown value;
- rotation, main-display, built-in, and mirroring facts;
- non-zero vendor, model, and serial numbers as optional reconciliation hints.

No pixels, windows, titles, application names, or user content are requested. The CoreGraphics
runtime display ID is suitable for correlating a currently connected topology, but it is not a
permanent identity. Vendor/model/serial values may be missing, duplicated, or changed by docks and
adapters. Product language and persistence must therefore describe displays, not promise durable
device identity.

`DisplayTopology` sorts descriptors before comparison and revision computation, because platform
enumeration order is not a semantic change. Its FNV-1a revision is a cheap deterministic change
token, not a unique ID or a security hash. Full topology equality compares full values; callers
must not use revision equality as proof of identity.

### ScreenCaptureKit later

ScreenCaptureKit is the preferred macOS 14+ capture path because it provides display-scoped streams,
content filters, configuration of frame cadence/resolution, and modern lifecycle callbacks. The
later capture slice must keep one independent stream and deduplication state per display, never
stitch displays, and destroy original-resolution surfaces after the fail-closed privacy pipeline.

Before starting any stream it must also handle:

- global/user collector confirmation in addition to OS authorization;
- lock/login and secure-input exclusions;
- application/site/password-manager/incognito exclusions;
- topology changes, display sleep/wake, mirroring, and authorization revocation;
- bounded queues and cancellation cleanup;
- proof that original frames never touch disk, logs, crash payloads, or diagnostics.

### Accessibility later

Accessibility can provide foreground window metadata and UI role/document context when authorized.
That path is substantially more sensitive than this preflight. It must be queried minimally behind
the shared privacy gate, treat unknown/sensitive roles as fail-closed, and never read or persist
typed values, passwords, selected text, or arbitrary control content. Accessibility authorization
is not permission to begin broad observation.

## Signing, entitlements, and manual verification gates

The Swift package can compile the metadata APIs without an app entitlement file, but a real app
bundle and stable code-signing identity are required to validate macOS TCC behavior. Rebuilding or
changing the bundle identifier/signature may produce a different permission record during local
development.

Before integrating collection, verify in a locally signed Debug app and again in an archived
Release app:

1. Bundle identifier and code-signing identity remain stable across launches and upgrades.
2. The Screen Recording usage description and hardened-runtime/App Sandbox choices match the
   selected distribution method and actual APIs.
3. A preflight check never opens System Settings or a consent dialog.
4. An explicit onboarding request opens the expected macOS flow only after a user action.
5. Authorized, denied, revoked, app-relaunch, OS-relaunch, and binary-update transitions are shown
   accurately without repeated prompting.
6. Accessibility access is separately explained, requested, detected, and revocable.
7. Two-display, dock reconnect, display sleep, rotation, mirroring, and main-display changes create
   sensible topology revisions without requesting pixels.
8. The Release binary contains no private API, telemetry SDK, or development endpoint.

Exact entitlement and sandbox decisions belong to the eventual Xcode application target and
distribution ADR. Screen Recording and Accessibility are TCC capabilities; their behavior cannot
be validated from a command-line Swift package alone.

## Current verification constraint

This workspace currently uses the standalone Command Line Tools rather than a full Xcode
installation. `./scripts/test` exercises compile-time API availability and pure tests, but it
cannot validate app-bundle signing, TCC prompts, System Settings deep links, ScreenCaptureKit
runtime behavior, entitlements, previews, or UI tests. Those checks remain blocked until full
Xcode is selected with `xcode-select` and the signed app target exists.
