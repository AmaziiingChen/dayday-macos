# ADR 0021: Personal-use data autonomy and local security boundary

- **Status:** Accepted
- **Date:** 2026-08-01

> ADR 0024 supersedes this ADR's launch-time per-collector confirmation rule and expands eligible
> visible-content collection for the Owner Deep Capture private profile. The credential, secure
> input, incognito, replayable-input, hidden-upload and report/journal boundaries remain in force.

## Context

Dayday v0.1 is used only by its product author on the author's own Mac. The author has explicitly
chosen comprehensive, useful aggregation of personal work data over generic consumer-product
privacy minimization. Existing documentation can otherwise be read as treating data minimization
as the product's overriding value, even when it removes a useful, locally owned signal the author
has deliberately enabled.

That decision must not accidentally turn into a blanket permission to retain credentials, replay
input, or silently broaden an existing collector. Dayday needs a durable rule that distinguishes
author-controlled data scope from data that weakens the author's own machine security.

## Decision

For the private v0.1 product, local data ownership, completeness, and user-directed control are
the priority. Dayday should implement an explicitly requested, useful local signal rather than
rejecting it solely to satisfy a hypothetical multi-user default. Product copy and design must say
what is collected, where it is stored, its retention period, where it appears, whether a model can
read it, and how the author can pause, delete, or export it.

Each collector remains independently consented, durably controlled, and non-prompting at launch.
An author can enable a fuller local recording scope through direct UI actions; the app may never
infer that consent from a macOS permission, prior use, or a broad global switch. Dayday keeps data
local unless the author explicitly enables a named provider or integration.

The following remain hard exclusions in every personal-use scope:

- passwords, passkeys, authentication/verification codes, secure-input values, API keys, private
  keys, tokens, and password-manager content;
- lock/login screens and incognito/private-browser context;
- typed characters, keystroke order, shortcut sequences, input-field contents, and clipboard
  history;
- exact replayable pointer-event history and raw coordinates; and
- original-resolution screen captures on disk.

These are local credential-security boundaries, not paternalistic restrictions on the author's
ordinary work context. Existing privacy-filtered application/window facts, bounded titles and
document hints, district weather, aggregate physical-key counts, normalized pointer grids, and
compressed redacted evidence remain eligible when their individual collector is enabled.

Any future proposal for a new high-fidelity data category must state its user value, exact data
shape, storage and retention, model/report access, disclosure and controls, migration impact, and
negative tests. A new ADR is required before changing a shared domain contract or persistence
schema. WorkReport/Journal isolation remains non-negotiable regardless of personal-use scope.

## Alternatives considered

- **Keep privacy minimization as the unconditional top priority:** rejected because it conflicts
  with the author's explicit private-use objective and can remove valuable local context without
  improving the author's control.
- **Add an unrestricted “record everything” switch:** rejected because it would make credential
  capture and unrecoverable local compromise too easy, while failing to explain the individual data
  contracts.
- **Use third-party trackers as the primary source:** rejected because their collection, storage,
  sync, and privacy semantics cannot be made Dayday's durable local contract.

## Privacy and security impact

The decision permits broader author-approved personal context, but does not add a collector,
network transfer, provider access, retention period, or model-access path by itself. Existing
negative controls, exclusions, and hard-stop ordering continue to apply. The mandatory exclusions
protect the same person who owns the device from credential disclosure through SQLite, backups,
logs, exports, prompts, or model requests.

## Migration impact

None. This ADR changes product decision criteria only. A later implementation that adds a new
durable data shape must introduce its own versioned contract, migration, tests, and rollback plan.

## Consequences

- Product work should favor useful, user-approved local aggregation over generic consumer defaults.
- Settings must expose granular, durable controls and clear local ownership/retention language.
- “Personal use” cannot be used to bypass secret exclusion, secure input handling, or report/journal
  isolation.
- Existing collectors do not become more permissive until a focused implementation slice accepts
  their new contract.
