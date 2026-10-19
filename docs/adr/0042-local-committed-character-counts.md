# ADR 0042: Committed-character counts are local, source-verified aggregates

- **Status:** Accepted
- **Date:** 2026-08-09

## Context

Physical key counts cannot represent the final text committed by an input method: Chinese input,
emoji, composed characters, autocorrection, deletion, and paste all make key presses diverge from
the user-visible character count. The product needs a local statistic for actual typed characters
that excludes pasted and otherwise unverifiable insertions.

## Decision

`InputAggregate` gains an unsigned `committedCharacterCount`. It represents the number of
user-visible grapheme clusters committed into an accessibility-exposed, non-secure text element
after a verified keyboard typing sequence. It is an aggregate only: no typed text, text range,
clipboard body, key order, or event timestamp is persisted.

The macOS capture layer uses two non-overlapping sources:

- Dayday-owned editors report only the number of graphemes inserted by a direct typing
  transaction. MarkEdit composes all provisional IME edits and reports once after composition
  ends; short direct-typing bursts are batched before crossing the WebKit bridge. Paste, drop,
  programmatic replacement, and document restore report zero.
- Other applications use a bounded before/after window around the focused caret. The window is
  primed when an admitted, non-secure focused editor becomes active, then sampled again only after
  a content-free typing signal and a quiet interval. Every synchronous AX call runs in a detached
  utility task with an 80 ms messaging timeout. Dayday's own process is excluded from this path so
  one edit cannot be counted twice. The delta uses total UTF-16 document length, the original
  selection, and the final caret to extract the inserted range; it never compares two moving
  caret-centred windows as if their offsets were identical.

The event-tap callback must remain constant-time: it may classify and enqueue an event, but it must
never query TCC, secure-input state, Accessibility, create a timer, perform persistence, or wait for
SwiftUI. Authorization and secure input are revalidated by the collector actor before any transient
event is admitted to an aggregate; a failed gate discards the event and closes the tap. Command
paste, mouse/menu paste, drag/drop, secure text fields, unsupported elements, and changes without a
preceding typing sequence contribute zero. A bounded window is retained only in process memory and
discarded on focus, consent, privacy, secure-input, and lifecycle boundaries.

The derived count has its own local preference. Turning it off stops and clears the AX sampler while
leaving the separately consented physical-key heat map available.

## Alternatives

- Count physical key presses. Rejected: inaccurate for IME and cannot exclude paste.
- Read the full document on every edit. Rejected: unacceptable cost for large Word documents.
- Persist text or clipboard material for later reconciliation. Rejected: unnecessary for the
  requested statistic and expands the durable data surface.

## Migration impact

Existing input-aggregate payloads decode with a committed count of zero. New payloads carry the
field without changing the SQLite table layout because the repository already stores a canonical
versioned aggregate payload.

## Consequences

- The UI must label this as verified typed characters, not an estimate or a productivity score.
- An unsupported application reports no character contribution instead of falling back to key
  counts.
- Status presentation is sampled at a bounded cadence; an individual key press must not publish a
  MainActor/SwiftUI update or rebuild a pointer grid.
- Real-Mac validation must cover Chinese IME, Word long documents, direct paste, menu paste,
  secure fields, deletion, undo/redo, the independent preference, and an Instruments check that no
  AX stack occurs on MainActor or the event-tap callback.
