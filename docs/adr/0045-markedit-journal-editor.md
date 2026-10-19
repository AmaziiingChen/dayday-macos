# ADR 0045: MarkEdit core for the private journal Markdown editor

## Status

Accepted.

## Context

The original journal canvas implemented Markdown presentation and editing directly with
`NSTextView`. It could handle a small set of headings, quotes, lists and attachment references,
but it could not faithfully provide the editing semantics expected from a Markdown editor:
CommonMark/GFM parsing, nested-list continuation, undo/redo, input-method composition and
formatting commands evolved independently and became fragile.

The owner selected MarkEdit as the editor foundation. MarkEdit is MIT-licensed and has a native
macOS host around a CodeMirror 6 editor. The current `main` branch requires macOS 15, while
Dayday supports macOS 14. The pinned `macos-14` release is the final Sonoma-compatible version:
commit `85e670450c1081d4ff92b85ce7052278a8c5e93d` (MarkEdit v1.26.2).

## Decision

- Dayday retains the complete pinned MarkEdit repository as the `ThirdParty/MarkEdit` submodule,
  including CoreEditor, MarkEditCore, MarkEditKit, MarkEditMac, PreviewExtension, build tools and
  tests. This preserves optional upstream capabilities for later product decisions without
  downloading a second mutable copy or silently following `main`.
- The shipping Dayday target links only `CoreEditor`, `MarkEditCore` and `MarkEditKit` as the
  journal Markdown engine. The full MarkEdit macOS application remains source-only and is not
  embedded in Dayday. Compiled CoreEditor resources load only from a local `WKWebView`; no journal
  request is sent to a network service.
- Dayday keeps its own SwiftUI navigation, journal repository, attachment ownership,
  location records, autosave and work-report isolation. MarkEdit's document model, external-file
  access, updater, AppleScript and preview extension are preserved in the pinned source but are not
  connected to the production target without a later compatibility and product review.
- The native bridge exposes only the editor's local text, formatting, selection and undo behavior.
  It rejects external navigation and does not provide file paths, save panels, user scripts,
  cloud services or journal text to any provider.
- The journal uses a calm writing configuration: system sans-serif type, 18-point base size,
  automatic wrapping, no line numbers, no active-line decoration and no separate preview pane.
- Dayday layers a local `dayday-live-preview.js` extension through MarkEdit's public CodeMirror
  extension API. It hides inactive Markdown markers, renders private attachment references inline,
  reveals the active line's source for predictable editing, and retains an explicit source-mode
  escape hatch. Markdown remains the only canonical document; this is Live Preview rather than a
  second rich-text representation or a lossy HTML round trip.
- Image bytes are served only through a private in-memory `dayday-attachment` WebKit scheme. The
  extension limits their display size and provides selection and deletion controls while Dayday
  retains attachment ownership and confirmation behavior.
- The MarkEdit copyright and MIT licence are retained in `NOTICE`; the exact snapshot, source
  path, generated resource hash and build procedure are recorded under `docs/external-sources/`.

## 2026-08-11 capability follow-up

The owner explicitly approved journal AI and future editor capabilities without treating privacy as
a product-level exclusion criterion. This does not make the latest MarkEdit application a drop-in
replacement: Dayday still supports macOS 14, while current MarkEdit releases and the official
`MarkEdit-ai-writer` extension require newer editor APIs and, for the latter, macOS Tahoe with Apple
Intelligence enabled.

- Keep v1.26.2 as the Sonoma-compatible production editor until Dayday raises its deployment target.
- Backport focused editor improvements only when they have an acceptance test and recorded MIT
  provenance; do not merge the complete newer application host into Dayday.
- Use Dayday's existing OpenAI-compatible text-provider configuration for the first journal AI
  implementation so macOS 14 users receive the same actions. Add Apple's Foundation Models as an
  optional newer-system backend later.
- The first actions are organize, rewrite, continue writing and proofread, matching the existing
  `JournalDerivedOperation` domain. Generated Markdown is previewed and retained as a derived
  version; it is not silently substituted while the user is typing.
- Editor extensions are prioritized by journal-writing value: structural list indentation and
  continuation, find/replace, table navigation/editing, outline navigation, text completion, then
  optional formatting and extension management.

## Privacy and supply-chain impact

The editor bundle contains no analytics, network origin or remote runtime and uses a non-persistent
WebKit data store. `WKWebView` loads its own bundle and attachment resources through constrained
custom URL schemes. JavaScript-to-native messages are limited to the reviewed MarkEdit bridge and
attachment selection/removal events. Updating the editor requires a new fixed commit, licence and
dependency review, regenerated resource hash and focused editor smoke tests.

## Alternatives

- Extend the handwritten `NSTextView` codec: rejected because each new Markdown construct would
  create another incomplete editing rule and risks text corruption.
- Use MarkEdit `main`: rejected because it silently raises Dayday's minimum system version to
  macOS 15.
- Add Electron or an externally hosted web editor: rejected because both undermine the native
  shell, local-first boundary and small runtime requirement.
