# Multi-Agent Development Protocol

## Purpose

This protocol lets independent agents work quickly without silently diverging on product
semantics, data ownership, or shared interfaces.

## Sources of truth

In descending priority:

1. The user's latest explicit decision.
2. `AGENTS.md` and accepted ADRs under `docs/adr/`.
3. `docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md`, and `docs/DATA_MODEL.md`.
4. Module-local documentation and tests.

When sources conflict, stop changing the affected interface, record the conflict, and ask the
root agent to resolve it. Never choose a product policy implicitly in implementation code.

## Work ownership

Every parallel task declares:

- owned files or directories;
- shared interfaces it may consume but not change;
- its expected deliverable and verification command;
- blockers requiring coordination.

Only one active agent may own a path. Generated project files count as owned paths.

## Shared contracts

The following require coordination before modification:

- identifiers and semantics of Event, Session, Activity, WorkReport, JournalEntry, MoodEntry,
  WeatherSnapshot, InputAggregate, EvidenceFrame, and ModelUsage;
- database schema and migrations;
- retention, exclusion, and redaction behavior;
- module boundaries and dependency direction;
- MCP/local API request and response contracts;
- model-provider usage accounting.

Propose a contract change in a short ADR containing context, decision, alternatives, privacy
impact, migration impact, and rollout plan. The root agent accepts or rejects it.

## Status protocol

Agents report at meaningful boundaries, not on a timer:

- `STARTED`: paths owned and intended output;
- `BLOCKED`: exact conflict or missing decision, plus safe work still possible;
- `CONTRACT`: proposed shared-interface change before implementation;
- `DONE`: changed paths, tests, open risks, and suggested next task.

The root agent maintains the integrated plan and resolves cross-module questions.

Long-running user-visible task windows additionally follow `docs/WORKSTREAMS.md`. That registry
defines the integration authority, exact-base work item envelope, `READY` handoff, stale-work rule
and sequential merge queue. A private task conversation is never assumed to synchronize another
task; accepted decisions must be written to the repository and relayed with an exact commit.

## Branch and integration discipline

- Each long-running task works in its own worktree from an exact accepted base commit.
- The primary task is the only integration authority and owns shared documentation, manifests and
  generated project files unless it delegates a specific file.
- Workstreams submit focused commits; they do not merge or rebase another workstream.
- After an integration changes a consumed contract, affected workstreams pause and rebase before
  continuing. Parallel work on both sides of an unsettled interface is prohibited.

## Merge readiness checklist

- Scope stays within assigned paths.
- Product and privacy invariants remain intact.
- New shared behavior is documented and tested.
- No secrets, personal data, screenshots, or machine-specific absolute paths are committed.
- Relevant tests/builds pass, or failures are clearly documented.
- Handoff lists assumptions and unresolved risks.

## Delivery-efficiency rules

Reliability is necessary, but a growing set of isolated contracts is not product progress by
itself. Every implementation slice must name the user-visible or production-pipeline capability it
unblocks. Prefer a small end-to-end increment over another speculative framework layer.

Before assigning a slice, the primary task performs an interface-readiness preflight:

- required initializers and symbols are visible to the owning module;
- the assigned protocol can be implemented without an unapproved shared-contract change;
- the schema can represent every closed variant without generic payloads;
- legal test fixtures can be constructed through public APIs;
- no active task owns a required path.

Verification is tiered:

- **L0 task gate:** focused tests, strict format and `git diff --check` for each task revision.
- **L1 integration gate:** affected-module tests, full `./scripts/test` and SwiftPM Release for each
  accepted READY stack.
- **L2 milestone gate:** Q0, unsigned Xcode Release, privacy/secret scan, independent high-risk
  review and real-Mac smoke at a complete vertical checkpoint.

Database migrations, permission/lifecycle code, privacy gates, provider usage accounting and
report/journal isolation may require L2-strength independent review before integration. Pure
presentation adapters do not receive repeated full independent audits unless they cross a privacy
or persistence boundary.

READY work is reviewed in the primary task's next integration cycle. Request required fixes once,
keep the revision narrow, then integrate or reject it; do not leave READY stacks aging across
multiple incompatible bases. After each green vertical milestone, update the operational docs and
push a recoverable remote checkpoint.

## Initial module ownership

- `DaydayCore`: domain models, clocks/day boundaries, policies, pure transformations.
- `DaydayStorage`: SQLite persistence, migrations, retention, backup/import/export.
- `DaydayCapture`: ScreenCaptureKit, application/window, display and input event collectors.
- `DaydayUnderstanding`: OCR, evidence selection, Session/Activity construction.
- `DaydayAI`: provider adapters, structured observations, usage and cost accounting.
- `DaydayIntegrations`: Chrome native messaging, EventKit, weather, local API/MCP.
- `DaydayApp`: SwiftUI application, menu bar, windows, views, onboarding and settings.

Dependency direction is App/Integrations/Capture/Understanding/AI/Storage -> Core. Storage and
provider implementations must remain replaceable behind protocols.
