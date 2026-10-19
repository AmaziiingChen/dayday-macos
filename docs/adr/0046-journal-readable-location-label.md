# ADR 0046: Persist the journal's readable place label with its location snapshot

## Status

Accepted.

## Context

The journal stores a one-time coordinate and the accuracy reported by Core Location. Reverse
geocoding previously produced a Chinese place label only in memory, so a reopened entry fell back
to coordinates even after Dayday had recorded that location. Coordinates are useful evidence but
are not a humane primary label in a journal.

## Decision

- `JournalLocationSnapshot` gains an optional, bounded `placeName` value.
- The first actual edit in a journal writing session requests one foreground location capture
  automatically; merely opening or reading the entry does not request location. A manual update
  remains available, and a denied permission never blocks writing.
- A new capture reverse-geocodes the one-time location before inserting the snapshot and stores the
  resulting province → city → district → road label in the same owner-only payload.
- Existing snapshots remain valid because the field is optional. Legacy snapshots may be resolved
  again for display, while a failed lookup never prevents the factual coordinate from being saved.
- The readable label is presentation context only. Coordinates, capture time, and system-reported
  accuracy remain the factual location record.

## Alternatives

- Keep the label in process memory: rejected because reopening the diary loses the useful context.
- Store labels in application preferences keyed by snapshot ID: rejected because it would split one
  personal artifact across unrelated persistence mechanisms.
- Replace coordinates with an address: rejected because reverse-geocoded labels are provider-derived
  and less precise than the original Core Location observation.

## Privacy impact

The readable label is derived only after the person begins editing a journal or explicitly updates
its location. It stays inside the same local journal-location repository and is never admitted to
work-report generation, telemetry, or a background location stream.

## Migration impact

No SQLite schema migration is required: snapshots are stored as canonical JSON payloads and the new
field is optional. Old payloads decode without a place label and preserve their original canonical
form.

## Consequences

Reopened journal entries can show a stable human-readable place. Reverse-geocoding failure remains a
recoverable display limitation and does not discard the captured coordinate.
