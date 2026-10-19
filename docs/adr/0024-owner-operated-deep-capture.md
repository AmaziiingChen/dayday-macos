# ADR 0024: Owner-operated deep capture is the private build priority

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

Dayday is currently built first for, operated by, and used only by its author on the author's own
Macs. Its purpose is not merely to count application time. It is intended to become a dense,
long-lived personal context archive from which local software and author-configured AI providers
can reconstruct what happened, prepare a useful work report, and support later personal analysis.

Earlier product rules optimized permission ceremony and data minimization for a hypothetical public
audience. That made the private build safer by default, but it also removed context the author has
explicitly said is valuable: rendered web-page context, visible conversation content, richer window
context, and content-free estimates of how much text was produced. For the private build, losing
these signals is a larger product failure than requesting broad local permissions.

This decision extends ADR 0021. It does not authorize credential capture, a replayable keylogger,
hidden network transfer, or using personal journal content to generate a work report.

## Decision

### Private build profile

The current product profile is **Owner Deep Capture**. It is the default development and dogfood
profile. After one concise first-run explanation, Dayday should immediately begin the supported
macOS authorization sequence and request every permission needed by enabled private-build
collectors. It does not require a second Dayday-specific confirmation for each collector before
showing the corresponding macOS prompt.

macOS remains the authority for permissions. Some permissions open System Settings rather than
returning a prompt, and some prompts cannot be requested concurrently or before the relevant API is
used. Dayday must therefore present this as one guided authorization run, show the exact state of
every capability, and continue automatically as permissions become available. Denial must degrade
the affected collector without blocking unrelated collection.

The menu bar retains a visible recording state and a global pause. Settings retain per-source
status, pause, retention, export, and deletion controls. These controls exist for observability and
recovery, not as repeated permission ceremony.

### Data scope to pursue

The private profile should collect the richest technically reliable local context that has an
identified use. In addition to existing application, window, display, input aggregate, weather,
calendar, screen, and lifecycle facts, accepted development targets include:

- authenticated Chrome context: tab title, normalized URL, domain, path, navigation, media state,
  and rendered page text or a bounded semantic page projection;
- visible application content obtained through Accessibility, OCR, or an application-specific
  connector, including visible conversation messages in author-selected chat applications;
- bounded window/document titles, document hints, visible control labels, selected-text metadata,
  and source/provenance needed to explain when and where content was observed;
- aggregate text-production facts such as physical key count, text insertion count, estimated
  Unicode scalar/grapheme/word count, correction count, and active writing intervals, computed
  without retaining the typed character stream; and
- compressed evidence derivatives sufficient to audit an Activity or report conclusion, subject
  to explicit storage budgets and retention.

Visible content is eligible for durable local storage in a dedicated content/evidence archive after
redaction and source classification. It may be used by the understanding pipeline and by an
explicitly configured BYOK task. The archive must preserve observation time, source, provenance,
redaction state, and whether the record is objective text or an inference. It must not silently turn
screen text into a user-authored statement.

### Security boundary that remains

Owner Deep Capture is broad, but it is not unrestricted. Dayday must still exclude:

- passwords, passkeys, authentication and verification codes, payment fields, recovery phrases,
  private keys, API keys, access tokens, and password-manager content;
- secure-input fields, lock/login screens, and Chrome private/incognito contexts;
- raw keystroke order, character-by-character input streams, shortcut replay, clipboard history,
  and any implementation whose durable output can reconstruct a password or typed conversation;
- exact timestamped pointer-event history or replayable raw pointer trajectories;
- original-resolution screenshots on disk; and
- hidden telemetry or undeclared network transfer.

The distinction is intentional: Dayday may store what was visibly present in an allowed window
after classification and redaction, but it may not become an input interceptor. It may count how
much was typed, but it may not persist which keys produced the text. Incognito, secure input, and
credential surfaces contribute zero content and zero input aggregates.

WorkReport and Journal remain sibling artifacts. Work-report generation cannot read journal text,
journal fragments, mood records, or private journal attachments even in Owner Deep Capture mode.

Dayday's own windows are a mandatory screen-capture exclusion. ScreenCaptureKit filters out the
current Dayday application (with an own-window fallback during application-list transitions), so a
visible journal, settings page, or diagnostic surface cannot enter OCR, visual evidence, or work
context. While Dayday is the active application or owns the key window, application composition
also removes every display target and cancels pending/in-flight local OCR. Capture resumes from the
latest reconciled display targets only after Dayday is no longer being interacted with. This second
gate protects interactive latency; it does not weaken the permanent self-exclusion boundary. The
same self-exclusion is applied before the production Accessibility window snapshot or observer is
installed, and display-topology polling is suspended for the duration of host interaction. A
trusted local journal editor may still report only its finalized grapheme count to the aggregate
input runtime; it does not route journal text through Accessibility or expose it to work context.

Interactive Markdown work is also kept off the Chinese input-method commit boundary. MarkEdit maps
existing decorations while text is being composed, coalesces preview reconstruction until one
true post-composition quiet period, and batches the exact count notification on that same trailing
idle path. Native Markdown snapshots and autosave therefore receive the final document after a
quiet interval instead of competing with every candidate-word confirmation.

### Future public profile

A future public build may introduce a separate **Standard Private** profile with granular opt-in,
narrower retention, and conservative defaults. That profile must be implemented as an explicit
policy configuration over shared collectors and storage contracts. It must not silently weaken the
private author's profile during current development.

## Alternatives considered

- **Keep the existing explicit-per-collector private default:** rejected for current development
  because it prioritizes hypothetical distribution concerns over the author's stated use.
- **Record every raw key, pointer event, screenshot, and network response:** rejected because it
  creates a credential-replay archive without adding corresponding personal-memory value.
- **Use only third-party trackers such as WhatPulse:** rejected as the primary architecture because
  their client APIs expose only the data they choose to aggregate and cannot provide Dayday's full
  evidence provenance or report/journal isolation.
- **Defer rich content until public-release design is settled:** rejected because the unavailable
  historical context cannot be reconstructed later, and the private dogfood period is intended to
  validate this richer product.

## Privacy and security impact

This materially increases the sensitivity of the local database and evidence archive. The
implementation must treat FileVault and macOS account security as a minimum, use Keychain for
provider and connector credentials, redact secrets before durable storage or provider requests,
and provide scoped deletion/export. Before persistent visible-content capture is enabled, the
storage slice must define retention, capacity, schema migration, diagnostic exclusion, and negative
tests for secure input, credentials, private browsing, and journal/report isolation.

Third-party conversation content can contain information belonging to other people or employers.
Dayday will not present a legal-compliance claim for the private profile; the owner is responsible
for using it on devices and accounts they are authorized to record. Local-only storage and the
absence of hidden upload remain product requirements.

## Migration impact

This ADR changes product priority and permission orchestration, but does not by itself change an
existing schema. Each durable high-fidelity category requires a closed Core type, versioned
migration, source and redaction metadata, retention behavior, and focused tests before collection
is enabled. Existing privacy-closed input aggregates must not be broadened in place to contain raw
text or event order.

## Consequences

- Understanding, browser context, visible-content storage, and text-production aggregates move
  ahead of public-release permission polish.
- First-run onboarding becomes a guided request-all-supported-permissions flow for the private
  profile.
- Settings continue to explain what is active and what is stored, but are not the gate that makes
  every collector default-off.
- AI receives rich content only through named BYOK tasks with locally recorded provider/model and
  usage metadata.
- The security exclusions above remain mandatory and testable.
