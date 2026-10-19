# Dayday Quality Gates

This document defines the verification sequence. Q0 is automated and safe to
run repeatedly; later gates are deliberate real-Mac validation and are not
started by Q0.

## Q0 — daily non-interactive verification

Run from the repository root:

```sh
scripts/quality/q0-verify --base <accepted-base-commit>
```

For an uncommitted local change, omit `--base`; the default is `HEAD`. The
harness runs these gates and returns a nonzero status if any gate fails:

1. verifies that its generated cache directory is ignored by Git;
2. runs `git diff --check` against the selected base;
3. runs strict `swift format lint` only on Swift files changed from that base;
4. runs the complete SwiftPM test suite;
5. builds the SwiftPM Release product; and
6. builds an unsigned arm64 Xcode Release app.

The repository currently has pre-existing full-tree swift-format findings.
`scripts/quality/q0-verify --all-swift` is an explicit diagnostic for that
debt and is not expected to be green until a separately owned formatting slice
establishes a clean baseline. The default changed-file mode prevents new Swift
format drift without relabeling existing unrelated findings as a new failure.

All Q0 output stays in `.build/quality/`, which is already ignored. The
harness sets local SwiftPM and Clang cache paths, an Xcode DerivedData/package
cache path, and a Foundation-local home for Xcode's package-manifest
diagnostics. Per-gate command output is kept in `.build/quality/logs/`; the
terminal prints each status and tails only failing logs. It does not delete build products, launch Dayday, request TCC,
perform signing, use credentials, or intentionally access the network. The
Xcode invocation disables automatic package resolution and remote package
updates; the current project uses only its local package.

Q0 is a source/build gate, not proof of real collection behavior. Run it for
every focused slice before handoff, then include its exact result in `READY`.

## Real-Mac TCC gate

Do not start until H1 has a production-wired app runtime, a fixed local app
location and a stable test identity appropriate for TCC validation. The user
personally performs each permission action. Test Screen Recording,
Accessibility, Input Monitoring, Calendar and Reminders through grant, deny,
revocation while running, recovery, pause/resume, relaunch, sleep/wake and
user-session transitions.

Pass only when no automatic path prompts, every denial/revocation fails closed,
recovery is visible, and no raw frame or replayable input data is persisted.
Record the app identity, macOS version, display setup, consent transitions and
observed recovery behavior. Teamless moving/rebuilt app bundles are not valid
evidence for durable TCC behavior.

## Multi-display gate

Enter after the real-Mac TCC gate and only when the production capture runtime
is connected to reconciled display targets. Exercise at least the built-in
display and a 4K external display: independent activity on both screens,
primary-screen changes, hot unplug/replug, display rearrangement, scaling,
rotation, mirroring, sleep/wake and relaunch.

Pass only when each display retains an opaque, correct identity; ambiguous
mapping fails closed; historical input grids do not overlay incorrectly; and
capture recovers without turning a static reference screen or media display
into a high-frequency source. Store no screenshots or personal data in the
gate record.

## Burn-in gate

Enter after the TCC and multi-display gates pass and H1 can persist and show
real objective facts across a relaunch. Run a half-working-day smoke test, then
24-hour and 72-hour burn-ins under ordinary sleep/wake and display changes.

Track runtime, collection gaps, recovery count, process CPU, resident memory,
disk growth, database health and any privacy-boundary event. A crash,
unrecoverable collection stop, raw-frame persistence or replayable-input
persistence blocks progression and must be diagnosed before restarting the
affected burn-in window.

## Fourteen-day dogfood gate

Enter only after A01–A18 preflight is complete, feature work is frozen, backup
and recovery have been verified, the work-report/journal isolation suite is
green, and the TCC, multi-display and burn-in gates have recorded passes.

For 14 consecutive real workdays, record collection runtime and gaps,
Event/Session/Activity counts and corrections, report generation and editing
time, model usage and failures, CPU/memory/disk growth, evidence cleanup, and
privacy/isolation spot checks. A confirmed data leak, journal-to-report leak,
unrecoverable data loss, original-frame persistence or secure-input counting
requires fixing the defect and restarting the entire 14-day window. Other
serious defects require the primary task to define the affected revalidation
window.
