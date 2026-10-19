# ADR 0012: Ephemeral application and window context

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday needs objective foreground-application and focused-window changes, but the platform surfaces
used to observe them contain sensitive, unstable identifiers and free-form text. NSRunningApplication
can expose a bundle identifier and display name. Accessibility can expose full window titles,
document paths or URLs, and roles that reveal password, login, or authentication contexts.
Publishing those raw values, persisting them directly, or treating a failed privacy decision as
ordinary metadata would bypass the R06 privacy gate.

The source must also remain quiet: it may inspect current nonprompting Accessibility state after the
user has handled permission separately, but it cannot present TCC UI, poll continuously, or create a
second browser-context collector.

## Decision

ApplicationWindowContextMonitor is a module-internal, main-actor, event-driven source. It reads an
initial snapshot, observes foreground application activation through NSWorkspace, and registers one
Accessibility observer for both focused-window and focused-UI-element changes in the current
process when Accessibility is already trusted. Observing the focused element is mandatory because
focus can move from ordinary content into a secure text field without changing windows. Application
activation replaces that observer. start() and stop() are idempotent, both AX notifications are
removed at teardown, and an observation generation rejects callbacks already queued at teardown.
There is no timer. Window content is publishable only while both AX notification registrations are
active for the current foreground application. Initial or activation-time partial registration
failure produces a zero-content unknown fact instead of a nominally available snapshot. Readiness
also compares the registered process with the current foreground process, closing activation races.
If Accessibility itself is unavailable, the monitor may preserve the denied disposition but emits
no application or window content until a complete observation can be established.

The monitor requires two injected policy dependencies:

1. ApplicationWindowIdentityResolving maps the ephemeral raw bundle identifier to the existing
   opaque ApplicationIdentifier.
2. ApplicationWindowPrivacyFiltering admits bounded fields or returns an exclusion/unknown
   decision.

The injected filter is downstream of a nonreplaceable mandatory gate. Production composition may
inject only user bundle exclusions; password managers, login/authentication processes, missing or
oversized mandatory roles, and secure/password/authentication roles are classified structurally
before any product policy. The separate filter injection initializer exists only as a test seam and
cannot bypass that gate.

Both protocols and every raw platform type remain module-internal. Raw bundle identifiers, names,
window titles, document values, roles, PIDs, and AX objects exist only during synchronous capture
and filter evaluation. They are not public, Codable, or file-backed.

The only public product output is the non-Codable ApplicationWindowContextFact:

- finite observation time;
- optional opaque ApplicationIdentifier;
- optional bounded, privacy-filtered application display label;
- optional bounded, redacted window title;
- optional bounded document filename hint; and
- a closed disposition distinguishing available, missing application, missing identity, denied
  Accessibility, missing focused window, exclusion, and unknown safety state.

Filtered text has no public initializer. The built-in filter removes controls, normalizes
whitespace, redacts URL tokens, and enforces field-specific UTF-8 bounds with incremental byte
accounting. Every platform free-form string crosses a fixed scalar inspection budget before case
folding, normalization, tokenization, URL parsing, or copying; oversized mandatory identity/role
facts fail closed, while oversized optional content is omitted. Document output is at most a file's
last path component; non-file URLs and relative/schemeless hints containing raw query/fragment
delimiters or any percent escape are omitted. This fail-closed rule has no finite percent-decoding
depth to bypass. Chrome emits only opaque application
identity, bounded display label, and filtered window title. This slice emits no domain/path/tab
metadata and makes no claim about incognito state; authenticated Chrome context remains R04b.

Unknown privacy state fails closed with zero content. User-excluded applications, known password
managers, login/authentication processes, and sensitive/password roles produce an explicit
exclusion with zero content. Missing or denied Accessibility can retain only admitted application
identity/label metadata and never window title or document content.

## Alternatives considered

- **Persist raw AX metadata and redact later:** rejected because a later filter cannot undo a local
  sensitive-data archive.
- **Publish bundle identifiers to Core or App:** rejected because application identity already has
  an opaque catalog identifier and raw identifiers would spread policy responsibility.
- **Use a periodic polling timer:** rejected because activation and focused-window notifications
  provide the required state changes without a polling storm.
- **Treat missing AX values as empty strings:** rejected because missing, denied, and uncertain
  safety states have different operational and privacy meanings.
- **Parse Chrome document URLs here:** rejected because browser context requires its own
  authenticated native-messaging and incognito policy.
- **Request Accessibility from the source:** rejected because ADR 0009 makes the explicit
  permission requester the sole prompt-capable gateway.

## Privacy and security impact

The source calls only AXIsProcessTrusted() and never AXIsProcessTrustedWithOptions; starting or
resuming it cannot display a permission prompt. It takes no screenshot, observes no keyboard or
pointer events, reads no focused-control value, performs no network I/O, and writes no data.
Security-sensitive and uncertain observations fail closed before identity resolution or public
delivery of content. A same-window focus change into a secure role immediately emits a zero-content
exclusion, preventing the previous admitted context from remaining the latest fact.

The output fact is intentionally volatile. A public field being bounded and filtered does not by
itself authorize persistence or model-provider transfer.

## Migration impact

There is no persistence migration. No existing Core or Storage contract changes. If a later slice
persists application/window context, it must define a separate versioned projection rather than add
Codable here.

## Rollout

1. Land the injectable monitor, built-in filter, production notification/AX adapter, and tests.
2. Compose it only after enabled product consent, authorized nonprompting Accessibility state, and
   lifecycle runtime admission.
3. R06 must independently review the output, apply its mandatory privacy gate and retention policy,
   and define any persisted event projection.
4. R04b adds authenticated Chrome context separately; this source remains browser-semantic-free.
5. Validate activation, focused-window and focused-element changes, denial/revocation, teardown,
   observer-registration failure behavior, and mandatory exclusions on the user's real Mac before
   the v0.1 acceptance gate.
