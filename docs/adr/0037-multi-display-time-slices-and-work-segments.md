# ADR 0037: Visual understanding operates on multi-display time slices and structured work segments

- **Status:** Accepted
- **Date:** 2026-08-08

## Context

ADR 0036 improved visual understanding by sending a short chronological frame sequence, but its
unit of batching was an individual display frame. In a multi-display session, frames captured at
nearly the same time could be ordered as if one screen replaced another. A single, latest global
foreground-application fact was then attached to the whole mixed batch. The provider returned
free-form fields, which Dayday serialized into presentation text and later parsed before sending
it to the text-only work-report provider.

This cannot faithfully represent a common work pattern: typing in a communication application on
one display while reading project material, code, or a meeting view on another display. The global
foreground application is an input-focus fact, not a complete description of every display.

## Decision

Dayday's visual unit is a `ScreenVisualTimeSlice`: the per-display derivatives captured within a
short alignment tolerance, plus the local foreground-application/window fact at that time. A time
slice has at most one derivative for each display. A visual-provider request contains an ordered,
bounded sequence of time slices; it preserves display lanes rather than treating the images as a
single stream.

The visual provider returns one strict, structured `VisualWorkSegment` for the window. It contains:

- the visible primary work situation and cross-slice interaction;
- a separately labelled global input-focus application fact;
- one visible state and role for each represented display;
- the relationship between display roles (`coordinated`, `independent`, or `uncertain`);
- a bounded confidence value, evidence list, and explicit uncertainty list.

Roles describe how a screen participates in the visible work (`primary`, `reference`,
`communication`, `monitoring`, `independent`, or `unknown`). They are model inferences, not
claims that a window was used or read. The foreground application remains a system fact and may
not be substituted with a guessed product identity.

`VisualWorkSegment` is a typed Core payload attached to a durable visual-inference observation.
The existing bounded summary text remains only as a legacy/readable projection; report assembly
uses the typed payload whenever it is present. DeepSeek receives bounded structured work segments
through `WorkReportContext`, never screenshot bytes.

Pending compressed derivatives are stored in a bounded local retry queue (at most 64 derivatives)
before provider dispatch, then assembled by time slice. A transient provider or archive failure
leaves the evidence eligible for a later retry; a successful segment removes its exact queued
derivatives. When an unavailable provider exhausts queue capacity, the oldest pending derivative
is dropped rather than allowing unbounded local storage. This ADR authorizes only the existing
compressed, dimension- and byte-bounded derivative format in that queue, never an
original-resolution capture. Completed visual work segments remain independently addressable by
their existing observation IDs.

A visual request never crosses a 45-second capture gap. A window with fewer than three time
slices is flushed after 45 seconds of capture silence instead of being held until unrelated later
work arrives. Transient failures retry from the durable queue with bounded exponential backoff;
authentication failures wait for an explicit provider reconfiguration.

## Alternatives

- **Keep a global chronological image queue.** Rejected because it makes two simultaneous screens
  look like a sequential single-display workflow.
- **Stitch displays into an ultra-wide bitmap.** Rejected because it hides lane identity and makes
  already-small 4K text harder for the visual model to read.
- **Ask DeepSeek to reconcile visual summaries.** Rejected because the configured report model is
  text-only and cannot inspect the evidence that would resolve a visual ambiguity.
- **Depend on a remote model conversation or prompt cache.** Rejected because it is provider
  specific and cannot serve as durable local workflow state.

## Consequences

- The visual request/response contract and report projection gain a real schema rather than a
  formatted-text convention.
- A time slice may contain one display when another display is unavailable; its relationship is
  then `uncertain`, not an invented single-screen conclusion.
- The next implementation must test two displays that share a time slice, distinct independent
  display roles, a focus switch inside a visual window, and compatibility with existing v0.1
  inference observations.
