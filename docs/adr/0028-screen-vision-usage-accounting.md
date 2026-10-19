# ADR 0028: Persist content-free screen-vision provider accounting

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

ADR 0027 returns provider request identifiers and token counts but did not persist them. Continuous
visual inference needs auditable call counts, token totals and bounded failure categories without
retaining requests, screenshots, prompts, credentials or provider response bodies.

## Decision

Add a closed `ScreenVisionUsageRecord` and repository port in `DaydayCore`. Each attempted remote
visual inference stores provider host, model, start/end time, success/failure, a closed error
category, optional request ID and provider-reported token counts. It contains no content or endpoint
path. Records live in the sensitive `deep_capture_*` namespace and can be summarized by time range.

Upgrade that namespace from schema v1 to v2 with one additive usage table and time index. Existing
v1 objects and fingerprint are validated before migration; unexpected schemas still fail closed.

## Consequences

- Settings and diagnostics can show objective cost and reliability data.
- Failure logs do not expose screenshots, OCR, prompts, keys or response bodies.
- Work-report `ModelUsage` remains revision-bound and semantically separate.
