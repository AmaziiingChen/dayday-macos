# ADR 0041: Native journal writing, manual precise location, and text-only dictation

## Status

Accepted.

## Context

Dayday already persists a private, exact journal original independently of work reports. Its former
presentation was an undifferentiated `TextEditor` with disabled attachments, despite the product
requiring a calm macOS-first journal. The owner now requires a light, Apple-native writing
experience, Markdown, local images, voice input, and very accurate location at the time of a
personal entry.

Those requests affect private-data boundaries. A location history, retained microphone audio, or a
generic file reference would not be equivalent to a deliberate journal context and would conflict
with the local-first, minimum-collection product posture.

## Decision

- The journal remains a sibling of the work report. Journal text, images, exact location, mood, and
  dictation text remain structurally unavailable to `WorkReportContext`, work-report providers, and
  work-facing APIs.
- The macOS journal uses a native split layout: an uncluttered writing/reading surface, a narrow
  optional-context inspector, standard controls, keyboard focus, Dynamic Type, and system light/dark
  appearance. Markdown source and reading preview are two views of the same exact original; preview
  never rewrites source text.
- Voice input means the system Dictation capability in the standard editor. Dayday does not start a
  recorder, retain audio, upload audio, or construct a transcript service. If a future standalone
  audio-note feature is proposed, it requires a separate ADR covering microphone permission,
  retention, encryption, export, and deletion.
- Image import is manual. The production slice copies user-selected image bytes to an
  owner-only journal attachment store, index its existing `JournalImageAttachment` metadata by
  journal entry, and reference it with a generated relative key. The source file is not watched;
  imported private images are never submitted to a visual model by default.
- Precise location is a manual, one-shot `CoreLocation` request from the journal editor. It requests
  `kCLLocationAccuracyBestForNavigation` only for that short request and stores WGS-84 coordinate,
  acquisition time, horizontal/vertical accuracy, and altitude only when present. The UI reports the
  system-provided accuracy and must not promise more precision than that value. There is no background mode,
  periodic sampling, automatic reverse-geocoding upload, or implicit location from
  images.
- Apple Maps display is an explicit foreground user action. Reverse geocoding is the immediate,
  disclosed follow-up to the same explicit “record location” action; map tiles and a single
  coordinate can then be sent to Apple’s map service. The returned place label is held only in
  memory for the current app run and never replaces the local coordinate/accuracy record.
- Each optional capability is progressively disclosed. Image import needs only the chosen file;
  system Dictation follows its system settings; precise location shows a purpose-specific explanation
  immediately before the system prompt and remains usable without permission.

## Privacy impact

The journal becomes more capable without broadening work collection. Exact coordinates and imported
images are private, retained until user deletion, absent from AI and report inputs, and presented as
personal context. Dictation persists text that the person deliberately inserts but no audio. The
app does not infer location, emotion, or writing meaning from collected work facts.

## Migration impact

The current UI-only Markdown surface needs no database migration. On first open, image metadata and
one-time locations create separate version-1 SQLite namespaces; imported bytes live in a sibling
owner-only attachment directory. Existing journal originals are unchanged. Import failure removes a
newly copied file if its metadata cannot be persisted; entry-facing deletion remains a separate
attachment-lifecycle increment rather than an undocumented file operation.

## Alternatives

- **Use a web editor or copy a competitor's journal UI:** rejected. Dayday uses SwiftUI/macOS
  controls and an independent implementation; reference products inform purpose and restraint only.
- **Build a custom recorder/transcription pipeline now:** rejected. It would retain or process audio
  and require a substantially wider permission and privacy contract than text-only system dictation.
- **Continuous high-accuracy tracking:** rejected. The user needs the location where they chose to
  write, not a movement history; one-shot capture is more honest, lighter, and safer.
- **Put an absolute image URL into Markdown:** rejected. It breaks portability and lets moved source
  files silently invalidate entries. Attachments need a controlled local store and generated relative
  keys.
