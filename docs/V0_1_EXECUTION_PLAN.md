# Dayday v0.1 Complete Execution Plan

## Delivery rule

This plan continues from commits `eb4c85f` and `19123dc`. Work is delivered as small vertical
slices, independently reviewed, tested with the selected Xcode toolchain, and committed only at a
clean integration gate. Product scope is frozen to `PRODUCT_SPEC.md` and `ACCEPTANCE.md`.

The root agent keeps development moving without asking for routine implementation choices. Work
pauses only for a user-owned legal/consent action, a destructive data decision, an external
credential, or a product decision that would materially change the accepted scope.

## First usable checkpoint

The complete A01-A18 scope remains v0.1, but the first user-testable checkpoint is deliberately
smaller and vertical. It is complete only when all five behaviors work in the production Debug
app without preview fixtures:

1. Explicitly enabled collectors write privacy-safe objective facts to `ProductionDataStore`.
2. Today and the menu bar read those persisted facts and accurately show running, paused,
   permission-missing and failed states across relaunch.
3. Persisted facts form traceable Sessions and Activities without productivity/focus scoring.
4. A user-configured BYOK provider creates, stores, revises and exports a free-form work report
   through the journal-excluding `WorkReportContext` allowlist.
5. A real-Mac half-day smoke covers permission grant/revoke, lock/sleep, relaunch and multi-display
   changes. Synthetic 14-day/failure fixtures run before this smoke; elapsed 14-day dogfood remains
   the final release-following gate.

Work that does not directly unblock this checkpoint must justify why it is safety-critical or wait
behind the vertical loop.

## Remaining delivery steps

| ID | Deliverable | Principal exit gate | Dependencies | Parallel track |
| --- | --- | --- | --- | --- |
| R01 | Reproducible macOS app bundle, composition root, entitlements and launch/background lifecycle | Debug app launches as a real `.app`; menu bar and main window share one runtime; clean machine build documented | Current foundation | Platform |
| R02 | First-run onboarding and independently controlled permissions | Every collector is explained and starts only after confirmation; denial/revocation is recoverable | R01 | App/Platform |
| R03 | System, display and ScreenCaptureKit collector lifecycle | Multi-display streams recover across lock/sleep/restart/topology changes; original frames remain memory-only | R01, current coordinator/display identity | Capture |
| R04 | Application/window/Accessibility and authenticated Chrome context | Privacy-filtered foreground/window facts plus title/domain/path-only Chrome facts; incognito/query/body excluded | R02 | Capture/Integrations |
| R05 | Keyboard and pointer privacy aggregation | Unordered physical-key and normalized per-display pointer aggregates are persisted hourly; no replayable input | Current Core/Storage | Core/Capture/Storage |
| R06 | Privacy gate, evidence derivatives, deduplication, OCR and retention | Mandatory exclusions fail closed; no original frame reaches disk; redacted compressed evidence expires correctly | R03–R05 | Understanding/Storage |
| R07 | BYOK provider, Keychain, offline jobs, usage ledger and budget enforcement | OpenAI-compatible text/vision calls are optional, auditable and budget-bounded; local capture survives failure | R06 | AI |
| R08 | Event → Session → Activity construction and correction history | Hard boundaries and task-level merges are deterministic; user edits survive rebuilds; evidence is traceable | R04–R07 | Understanding/Core |
| R09 | Free-form work-report generation, revision, finalization and Markdown export | Useful daily report; confirmed versions never overwritten; input projection proves journal/mood exclusion | R07–R08 | AI/Storage/App |
| R10 | Journal, fragments, mood, weather, attachments and AI-derived copies | Original journal auto-saves and is never silently rewritten; weather is city-level; mood is only user-authored | Current foundation | Core/Storage/Integrations/App |
| R11 | Production Today, timeline editing, history and objective insights | Work overview, display state, heat maps, application/input history and report/journal flows use real data | R05, R08–R10 | App |
| R12 | Calendar/Reminders read-only, lightweight todos, localhost API and MCP | Least-privilege projections, bearer auth, bounded reads, audit log and confirmed mutations | R08–R10 | Integrations |
| R13 | Retention/rollups, backup/import/export, diagnostics and resource limits | 180-day rollup, rolling backup, safe restore, JSON/Markdown portability, rotating redacted diagnostics | R05–R12 | Storage/Quality |
| R14 | Automated acceptance, privacy, performance and failure-recovery gate | A01–A18 preflight passes; 1000+ Event UI remains usable; release build contains no telemetry/dev endpoints | R01–R13 | Quality |
| R15 | Feature freeze and continuous 14-day real-world validation | All final gates in `ACCEPTANCE.md` pass; daily report needs no more than about 3 minutes of edits | R14 | Dogfood |

## Parallel wave schedule

### Wave P1 — contracts and platform spine

- R01 app-bundle/composition design and reproducible project generation.
- R03 lifecycle notification bridge into the accepted collector coordinator.
- R05 closed InputAggregate contract and non-replayability policy.
- R10 closed report/journal/mood/weather isolation contracts.

Exit: interfaces needed by capture, storage and UI can evolve independently without privacy drift.

### Wave P2 — real objective data

- R02 onboarding and explicit permission requests.
- R03 ScreenCaptureKit ephemeral-frame pipeline.
- R04 application/window and Chrome collectors.
- R05 in-memory input accumulation and hourly persistence.
- R13 production repository composition and first backup/retention primitives.

Exit: a half day of real use creates a privacy-safe objective event stream without cloud AI.

### Wave P3 — understanding and personal data

- R06 privacy gate, evidence store, OCR and deduplication.
- R07 provider/Keychain/usage/budget infrastructure.
- R08 deterministic Session construction followed by evidence-linked Activity candidates.
- R10 journal/mood/weather repositories and functional UI.

Exit: one real day can be reconstructed locally; journal remains independently usable.

### Wave P4 — complete product workflows

- R09 work-report workflow and hard data projection isolation.
- R11 real Today/history/insights/editing surfaces.
- R12 EventKit, todos and local Agent access.
- R13 export/import, rollups, diagnostics and resource budgets.

Exit: every v0.1 workflow is usable without Debug tooling.

### Wave P5 — acceptance and freeze

- R14 automated A01–A18 matrix, privacy scans, release checks and stress/performance fixtures.
- Fix only acceptance blockers, then freeze features.
- R15 run the full 14-day protocol; restart the window only for the severe failures defined in
  `ACCEPTANCE.md`.

## Required review gates

Every wave requires:

1. Narrow tests from each owner.
2. Independent review of shared contracts, privacy boundaries and migrations.
3. Root integration test and release build with the selected Xcode version.
4. Secret/prohibited-capability scan and clean `git diff --check`.
5. A local Git checkpoint and `PROJECT_BOARD.md` handoff update.

## Non-compressible external gates

- The user must personally approve macOS permissions and provider/calendar credentials.
- Real ScreenCaptureKit, Accessibility, Input Monitoring and Chrome extension behavior must be
  exercised on the user's actual Mac and displays.
- R15 requires 14 elapsed days; agent parallelism cannot honestly shorten it.
