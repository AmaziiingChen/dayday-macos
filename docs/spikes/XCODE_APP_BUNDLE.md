# Reproducible macOS app bundle

## Scope

Dayday's Swift package remains the source of the reusable library products. The checked-in
`project.yml` adds one thin macOS application target that compiles `Sources/DaydayApp` and links
those local products. XcodeGen generates `Dayday.xcodeproj`; no source files are copied and no
remote package dependency is introduced.

The application target is macOS 14+, Apple Silicon (`arm64`), Swift 6, and produces `Dayday.app`
with the existing SwiftUI `@main` entry point, main window, and menu-bar extra. `LSUIElement` keeps
the application out of the Dock for its menu-bar-first v0.1 behavior; the normal window scene
remains available while the process is running.

## Clean-machine generation

Prerequisites are Xcode 26 or a compatible Xcode with the macOS 14+ SDK, Homebrew, and XcodeGen.
XcodeGen is MIT-licensed, is used only to generate the project, and is not linked into the app.
Its replacement cost is limited to maintaining the small generated Xcode project by hand or
switching to another project generator. The committed project was generated and byte-for-byte
regeneration-tested in a checkout whose directory is named `Dayday` with XcodeGen 2.45.4;
`project.yml` rejects versions older than 2.44.1. XcodeGen derives a local-package file reference
from the checkout directory name, so a differently named checkout can produce a harmless
generated-project diff even though the target graph is the same.

```sh
brew install xcodegen
./scripts/generate-project
```

The project is reproducible from `project.yml`, `Config/`, the local Swift package manifest, and
the application sources. Regenerate after changing the target graph, build settings, or
adding/removing files under `Sources/DaydayApp`, and review the generated project diff before
committing it.

## Teamless local build

The v0.1 development build has no paid-team or Apple Developer Program dependency. It deliberately
uses manual signing with an empty development team. Build a real app bundle without invoking an
Apple development/distribution identity with:

```sh
xcodebuild \
  -project Dayday.xcodeproj \
  -scheme Dayday \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The result is:

```text
.build/xcode-derived/Build/Products/Debug/Dayday.app
```

Because this private development build is rebuilt under a teamless local identity, Debug-only
provider and health-pairing credentials use dedicated local development preferences. This avoids
macOS Keychain treating successive local builds as different requesters and presenting a password
dialog on every launch. Release builds continue to keep both credential classes in the Keychain.
Switching an existing local health setup to this Debug storage requires one fresh iPhone pairing;
the old Keychain item is left untouched and is never read by the Debug app.

For interactive local development, use the repository launcher instead:

```sh
./scripts/run-local.sh
```

The `.env` file is optional; provider credentials can be configured in Settings. Create a
standalone Release ZIP and DMG with `./scripts/package-app.sh`. This uses
`DAYDAY_BUILD_CONFIGURATION=Release` and `DAYDAY_SIGNING_MODE=adhoc`; the default development build
continues to use Debug and the persistent local signing identity. Release credentials use Keychain.

When only standalone Command Line Tools are selected, this launcher builds `DaydayApp` with
SwiftPM's native build engine with the installed macOS 26 SDK and packages the executable, MarkEdit resources, permission
descriptions, and existing PNG app icon into the same `.app` path. This supports local use without
installing full Xcode; `DAYDAY_SWIFT_SDK_PATH` can select another compatible SDK. The Xcode build
remains the path for the Liquid Glass icon and Xcode tooling.

It builds into `.build/xcode-derived-signed`, then applies a teamless ad-hoc signature with the
stable `app.dayday.local` identifier and an explicit identifier-based designated requirement.
This prevents the linker-generated CDHash requirement from making every rebuild appear to macOS
privacy controls as a different application. The first build after adopting this launcher still
needs Screen Recording and Accessibility to be granted once in System Settings. Keep launching
the bundle from this same path; moving or copying it can still create another local TCC entry.

This is a local development artifact, not a distributable release. On Apple Silicon, the linker
may embed a teamless ad-hoc/linker signature even when Xcode code signing is disabled; this is not
Developer ID signing and has no team identifier. Public distribution still requires an explicit
signing/notarization decision, credentials, and release pipeline.

## Entitlements and permission boundary

`Config/Dayday.entitlements` is intentionally empty. App Sandbox is not silently enabled because
continuous local observation and later user-consented capture/accessibility integrations need an
explicit capability design; enabling broad entitlements speculatively would misstate the current
privacy boundary. This scaffold does not request Screen Recording, Accessibility, Input
Monitoring, Calendar, microphone, camera, network, or file permissions, and it does not start a
collector.

The current application may perform non-prompting permission preflight and display inventory reads
already implemented by the package. Any future permission usage string, sandbox exception,
automation entitlement, or collector startup must be added as a separately reviewed vertical
slice. The repository launcher stabilizes the identity of the local bundle across ordinary
rebuilds. Moving the bundle, changing its identifier/designated requirement, or switching to a
different signing identity still requires a fresh TCC smoke check. Teamless signing remains a
development convenience rather than a public distribution identity.

## Open risks

- The project consumes the repository as a local Swift package while separately compiling only the
  application source directory. Xcode/package-resolution behavior must remain covered by the
  teamless build command after package graph changes.
- `LSUIElement` is suitable for the present menu-bar-first shell, but discoverability and explicit
  main-window reopening need product-level UI verification before v0.1 acceptance.
- An empty entitlement file is correct for this non-collecting scaffold, not a prediction of final
  capture, EventKit, Keychain, browser-extension, or localhost API capabilities.
- Developer ID signing, hardened-runtime distribution validation, notarization, and updates remain
  deferred. The local launcher provides a stable development TCC requirement, not a distributable
  identity.
