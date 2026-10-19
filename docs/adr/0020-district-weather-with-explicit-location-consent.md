# ADR 0020: District-level weather with explicit location consent

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

The original weather contract limited persisted weather context to a city. The product owner has
explicitly requested district-level administrative weather (for example, Guangzhou Tianhe District)
because city-level weather is not sufficiently useful for local interpretation. Weather must refresh
while Dayday is actively used rather than presenting a daily value as if it were current.

This changes the meaning of the shared weather location contract and the privacy scope of weather
history. It must be explicit before location, provider, storage, or UI code is introduced.

## Decision

Weather is an optional, independently enabled collector. When the user enables automatic weather,
Dayday requests macOS foreground location permission. A successful location lookup is reverse
geocoded to a district-level administrative label and time zone, then queried through the configured
weather provider. The persisted weather location is the district label and opaque provider mapping
key; it contains no latitude, longitude, street address, postal address, or raw geocoder payload.

While the app is foreground-active, Dayday refreshes the current-weather snapshot at most once every
30 minutes and refreshes when it returns to the foreground if the last successful snapshot is older
than that interval. Each retained snapshot carries its observation and retrieval times, so historic
weather may reveal district-level location changes. Dayday does not request location in the
background and does not record an independent movement trail.

The initial provider is Open-Meteo. Only the current lookup coordinates are transmitted to the
provider, over HTTPS, to obtain weather; no application activity, journal content, work report,
account identifier, or API key is sent. Coordinates exist only for the in-flight location and
weather request and are discarded after the provider response is validated.

The existing city-only `WeatherSnapshot` location contract is superseded by a versioned
district-capable administrative-weather location contract. Storage migration must reject malformed,
coordinate-like, address-like, or unconsented legacy values rather than guessing their precision.

## Alternatives considered

- **Keep city-only storage:** preserves the former privacy posture but does not meet the explicitly
  requested analytical usefulness.
- **Persist coordinates:** would simplify provider refreshes but retains more precision than the
  product owner requested and increases movement-history risk.
- **Continuous background location:** improves freshness while consuming more privacy and battery;
  rejected in favor of foreground, interval-limited refresh.
- **Manual city only:** remains a future fallback but is not the requested default mode.

## Privacy impact

District labels and their timestamped changes are personal location context. They are collected only
after the user enables weather and grants macOS foreground location permission. The UI must disclose
that district-level history is retained, expose pause/disable controls, and state that disabling
stops future lookups without silently deleting existing snapshots. Raw coordinates and addresses
must never enter SQLite, UserDefaults, logs, WorkReport provider payloads, or diagnostics.

Weather remains objective environmental context. It must not be used to infer mood, health,
productivity, or causation. Work-report inclusion remains an explicit optional objective context
choice and must never provide raw coordinates.

## Migration impact

`CityWeatherLocation` and its city-only validation cannot be reinterpreted in place. Introduce a
new versioned administrative location representation and SQLite migration when weather persistence
lands. Pre-release city fixtures may migrate only when their label is a valid administrative label;
otherwise they are discarded with a visible unavailable state. No migration may derive a district
from city text or synthesize coordinates.

## Consequences

- Weather configuration requires a macOS location consent flow and a new district-level disclosure.
- Real-time display is bounded by provider availability and the 30-minute foreground interval; UI
  always shows the last successful retrieval time and an explicit unavailable state on failure.
- A user traveling between districts will have distinct district-attributed weather snapshots, but
  no retained coordinate series.
