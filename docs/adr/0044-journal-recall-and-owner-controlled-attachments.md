# ADR 0044: Journal recall, lightweight writing insights, and owner-controlled attachments

## Status

Accepted.

## Context

Dayday’s journal needed to function as a lasting personal record, not merely today’s editor. The
owner needs readable text, history recall, total writing counts and continuity, correct Chinese
place hierarchy, and the ability to remove an imported image completely.

Apple Journal validates calendar/search recall, location-based review, multimedia attachments and
private writing insights. Dayday must translate those ideas without reading activity history,
creating automatic suggestions, or allowing journal data into work-report inputs.

## Decision

- The journal canvas uses an 18-point macOS system font with more generous line and paragraph
  spacing; headings retain a larger system-font hierarchy.
- A local recall sheet lists up to 10,000 most recently updated journal days, supports body-text
  search, and shows total authored characters, distinct writing days and the consecutive streak
  ending on the most recently written day. These are neutral observations, not a productivity or
  wellbeing score.
- Deleting an image removes its Markdown reference, metadata record, in-memory thumbnail and its
  owner-only copied file. The action is explicitly confirmed. If a local file was already missing,
  metadata and the entry reference are still removed.
- Reverse-geocoded Chinese place labels are ordered administratively: province, city, district,
  road, house number, then any remaining provider name. Coordinates and reported accuracy remain
  the durable factual record.

## Privacy impact

Recall and statistics only read existing journal records from the local repository. Search never
uses the work timeline, report generation, AI provider or network. Image deletion only affects the
user-selected private attachment. Place-name lookup retains the previous explicit-action and
memory-only label policy.

## Alternatives

- Copy Apple Journal’s activity-driven suggestion system: rejected; it requires a wider personal
  data boundary than Dayday currently permits.
- Show a productivity score or target completion percentage: rejected; a streak and count are
  descriptive, while a score would impose a judgement the product explicitly avoids.
- Leave image bytes after a visible deletion: rejected; it would violate the person’s reasonable
  expectation that removal applies to both the entry and the private attachment store.

The memory-only place-label portion of this decision is superseded by ADR 0046, which keeps the
reverse-geocoded label inside the same owner-only location snapshot payload.
