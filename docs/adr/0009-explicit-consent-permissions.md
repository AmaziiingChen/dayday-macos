# ADR 0009: Explicit product consent and user-initiated permissions

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

Dayday has independently useful collectors with unusually different privacy implications. macOS
TCC authorization alone does not mean the user agreed to Dayday's purpose, retention, or data
shape. Conversely, product consent cannot grant a system capability. Treating both as one switch
would allow an authorized collector to start without an explanation, or cause launch, preflight,
resume, and recovery paths to repeatedly present system prompts.

Chrome context and fixed-city weather do not need TCC permission, but still process or retrieve
user-related context and therefore still require Dayday product consent. A denied or later revoked
TCC permission must remain recoverable without prompting automatically.

## Decision

Each `CollectorKind` has one closed `CollectorConsentDisclosure` explaining its purpose, collected
summary, explicit non-collected summary, and platform-permission requirement. The mappings are:

| Collector | Platform requirement |
|---|---|
| Screen understanding | Screen Recording |
| Application/window context | Accessibility |
| Chrome context | No TCC; product consent still required |
| Keyboard aggregates | Input Monitoring |
| Pointer aggregates | Input Monitoring |
| Calendar | Calendar full read access |
| Reminders | Reminders full read access |
| Weather | No TCC in fixed-city mode; product consent still required |

Product consent is represented independently as `unconfirmed`, `enabled`, `disabled`, or
`paused`. Every transition out of or between confirmed states carries a bounded disclosure version,
finite confirmation time, matching collector, and an explicit user action. Decoding revalidates
these invariants. Only `enabled` consent permits a TCC request or future collection. Pausing is a
product decision and does not erase the prior TCC fact; disabling or pausing never equates to an OS
denial.

`ExplicitPermissionRequester` is the sole production gateway to prompt-capable platform adapters.
It accepts an explicit trigger and calls its injected adapter only when the trigger is
`userInitiated` and matching product consent is enabled. `applicationLaunch`,
`authorizationPreflight`, and `automaticResume` are fail-closed outcomes and cannot invoke the
adapter. Existing preflight APIs remain read-only and non-prompting.

The prompt-capable adapter protocol, macOS adapter type, and dependency-injection initializer are
module-internal. Other modules can construct only the public live requester or depend on the
policy-bearing `PermissionRequesting` abstraction, so they cannot call a TCC API adapter
directly. The `userInitiated` value is a policy label, not cryptographic proof of a physical
gesture; the composition root must pass it only from the synchronous user-control action path.

The platform adapter protocol covers Screen Recording, Accessibility, Input Monitoring, Calendar,
and Reminders. The macOS implementation uses the corresponding request API only behind that
gateway. Tests inject a spy adapter, so automated verification can prove prompt suppression without
presenting real TCC UI.

Request results are authorization facts only. This slice never configures or starts a collector.
Authorized facts have no recovery action. Denied, restricted, revoked, and unknown facts include a
typed `SystemSettingsDeepLinkDescriptor` for the relevant privacy pane. Constructing this descriptor
does not open System Settings; following it remains a separate user action in a later UI slice.
Its Codable representation stores only the closed permission fact; the privacy-pane URL is always
derived from that fact, so persisted or imported data cannot substitute an HTTP or file URL.
For EventKit read collectors, only full access authorizes collection. A write-only Calendar grant is
an explicit `insufficientAccess` fact and fails closed. The application bundle supplies
`NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`, and
`NSScreenCaptureUsageDescription` purpose strings.

Collector startup requires three independently valid conditions in later orchestration:

1. product consent is `enabled`;
2. TCC authorization is `authorized`, or the collector's requirement is `notRequired`; and
3. collector runtime policy permits running and no pause/privacy boundary is active.

The ScreenCaptureKit stream enforces the first two conditions with a single-use,
non-publicly-constructible start authorization. Its public gate reads a concrete
`ScreenCaptureConsentLease` plus an authorized non-prompting Screen Recording preflight. The lease
is updated from validated `screenUnderstanding` consent transitions and cannot be replaced with an
arbitrary validator. Authorization rechecks both live consent and preflight before and after the
asynchronous backend start and cannot be reused; public callers cannot directly start a stream
without it. Lease construction and mutation remain module-internal until a Capture-owned consent
runtime is wired, so App composition cannot prematurely create a live token. Runtime suppression
remains independently owned by lifecycle orchestration.

## Alternatives considered

- **Use TCC authorization as consent:** omits Dayday's purpose and retention disclosure, and cannot
  represent Chrome or weather consent.
- **One onboarding “allow all” action:** faster, but hides materially different data contracts and
  prevents independent revocation.
- **Prompt missing permissions at launch:** convenient for implementation, but surprising and
  repeatedly disruptive after denial or revocation.
- **Prompt during preflight or automatic resume:** conflates observation with mutation and makes a
  background process capable of presenting UI.
- **Open System Settings immediately after denial:** can create a prompt loop and removes the user's
  choice about recovery timing.
- **Let each collector call platform APIs directly:** duplicates policy and makes it difficult to
  prove that no automatic path prompts.
- **Treat Chrome/weather as implicitly enabled because no TCC exists:** mistakes lack of an OS gate
  for informed product consent.

## Privacy impact

No collector starts and no TCC prompt occurs merely because Dayday launches, checks authorization,
wakes, or automatically resumes. Product consent records contain only collector, state, time, and a
bounded machine disclosure version; they contain no captured data or free-form user text.

Disclosures explicitly state prohibited data for every collector. In particular, keyboard and
pointer consent never expands the aggregate contracts to typed text, key order, exact coordinates,
or replayable trajectories. System Settings links contain only privacy-pane destinations and are
never opened automatically.

## Migration impact

This is version one of product consent. Existing installations must initialize every collector as
`unconfirmed`; existing TCC grants must not be imported as enabled product consent. Persistence must
round-trip and revalidate the collector/status/confirmation relationship.

Disclosure wording changes that materially change purpose, collected data, exclusions, retention,
or remote transfer require a new disclosure version and a product decision about renewed consent.
Adding a collector or platform permission requires an exhaustive mapping update, tests, and an ADR
review. Future optional weather location permission is a separate capability and cannot reuse the
current fixed-city `notRequired` mapping silently.

## Consequences

- Onboarding and Settings can render every collector from one exhaustive contract.
- UI code must first record a user confirmation, then explicitly request any required TCC access.
- Permission denial/revocation is visible and recoverable without repeated prompts.
- Capture coordination must combine consent, authorization, and runtime rather than using one
  enabled boolean.
- Real macOS adapters remain small and replaceable; automated tests never need to exercise TCC UI.
- A later UI slice must deliberately follow System Settings descriptors and re-run non-prompting
  preflight when the app becomes active.
