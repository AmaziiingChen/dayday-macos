# ADR 0002: Event, Session, and Activity hierarchy

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Application duration alone cannot describe knowledge work. A single task can involve Xcode, a
terminal, and Chrome across several displays; a static reference screen can remain relevant without
input; and application switches or brief messaging interruptions should not mechanically fragment
the day. At the same time, model interpretations must not erase objective observations.

## Decision

Logical workdays use the user's local wall clock. When a configured boundary falls in a
daylight-saving gap, the boundary is the first valid local time after the requested time; when it
occurs twice, the first occurrence is used. A nonexistent boundary is resolved only within its
intended civil day; it must never spill into the next day. Calendar and time zone are injected,
calculation failure is explicit, and tests cover both one-hour and sub-hour transitions.

Use the hierarchy `Event -> Session -> Activity`:

- **Event** is an objective timestamped observation or safe aggregate. It contains no claim about
  goal, emotion, productivity, or focus.
- **Session** is an objective contiguous interval with stable application/window, document/tab,
  display, or interaction context, derived from Events.
- **Activity** is an editable semantic conclusion that groups one or more Sessions by common task,
  across applications and displays when appropriate.

Interpretation follows `Fact -> Inference -> Conclusion`:

- facts link directly to Events, OCR, evidence, integrations, or user-authored work notes;
- inferences link to supporting/conflicting facts and carry a coarse confidence band and
  rule/model provenance;
- Activity membership/title/category and report statements are conclusions that can be corrected
  by the user.

Every display is captured and deduplicated independently. Unchanged secondary-screen semantics are
reused; significant changes trigger analysis. Displays are not stitched into an ultra-wide image.
Activity span and detected-interaction duration are separate objective values. “No input detected”
is not interpreted as absence or lack of focus. Core `WorkdayBoundary` assigns records to logical
days using an injected `Calendar` and time zone, a configurable hour in `0...23`, and a default of
04:00.

## Alternatives considered

- **Application-duration-only records:** objective and cheap, but cannot connect tools serving one
  task or describe task meaning.
- **One screenshot equals one activity:** simple, but creates noisy fragments and makes model guesses
  look like source facts.
- **Model-generated activities without retained Events/Sessions:** compact, but unauditable and hard
  to correct or regenerate.
- **User-started focus timers:** require manual behavior and introduce a focus concept the product
  explicitly rejects.
- **One stitched multi-display image:** easy to send, but shrinks text, harms per-display deduplication,
  and obscures source identity.

## Privacy impact

Separating layers makes it possible to delete short-lived evidence while retaining objective
structured history, explain a conclusion without exposing evidence by default, and prevent weak
inference from becoming fact. Original-resolution frames remain ephemeral; only privacy-filtered,
compressed selected evidence may persist. Individual key or mouse events are not Events.

## Migration impact

Every derived Session and Activity records a derivation version and may supersede an older version.
Changing segmentation or inference logic can rebuild derived records from retained objective data
without mutating user overrides. Identifier, boundary, membership, and user-override semantic
changes require a new ADR and persistence migration.

## Consequences

- More storage relationships and derivation logic are required than a flat timeline.
- Timeline UI can remain task-oriented while Activity details retain application/display evidence.
- User split/merge/category corrections remain authoritative over future model passes.
- Reports can use task conclusions while qualifying or omitting low-confidence material.
- No focus, distraction, or productivity score is derivable as a first-class field.
