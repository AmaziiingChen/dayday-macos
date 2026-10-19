# ADR 0022: Modifier-key physical counts without modifier history

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

The CGEventTap adapter in ADR 0017 observed only `keyDown`. macOS emits ordinary modifier
actuations such as Shift, Control, Option and Command through `flagsChanged`, so the keyboard
heatmap undercounted both built-in and Bluetooth keyboards. The persisted input contract already
permits unordered physical hardware-key counts, but it prohibits modifier sequences and
combinations.

## Decision

The listen-only callback also receives `flagsChanged`. For the known physical modifier hardware
codes it reads the event's current modifier flags solely to classify the transition as a press or
a release. A tiny callback-local set is used only to disambiguate left and right variants when
both are held. Caps Lock contributes once for each toggle event. The only value passed to the
existing accumulator is the same `UInt16` physical hardware key code used for ordinary `keyDown`.

The callback does not expose, serialize, log, store, or send modifier flags, combinations, event
order, timestamps, or a modifier state history. Secure input and every existing gate remain ahead
of this classification, so denied contexts contribute zero. Auto-repeat remains excluded.

## Consequences

- The keyboard heatmap can show the pictured physical modifier keys for built-in and external
  keyboards where macOS sends standard `flagsChanged` events.
- The output schema, SQLite migration state, and WorkReport inputs do not change.
- Media/function system actions that macOS does not deliver through either `keyDown` or
  `flagsChanged` remain outside this standard event-tap slice and must not be guessed or
  synthesized.
