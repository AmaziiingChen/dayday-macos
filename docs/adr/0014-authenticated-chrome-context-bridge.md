# ADR 0014: Authenticated Chrome context bridge

- **Status:** Proposed
- **Date:** 2026-08-01

## Context

Dayday needs active Chrome tab title, domain, path, navigation, tab-switch, and audio facts without
collecting browsing secrets or creating a cloud dependency. Chrome Native Messaging supplies a
local byte stream, but its framing is not authentication. Any local process able to reach a native
host could otherwise forge context, reset its sequence, replay old messages, or send arbitrarily
large values. A full URL and extension payload can contain user-info, query parameters, fragments,
page bodies, form values, and incognito context that Dayday prohibits from persistence or model
transfer.

This slice defines the security and minimization boundary. Extension manifests, unpacked-extension
installation, native-host registration, Keychain provisioning, reconnect orchestration, and public
signing/store distribution remain separate rollout work.

## Decision

The local protocol uses Chrome's four-byte unsigned little-endian length prefix. Each frame is
limited to 64 KiB and contains one strict JSON envelope with exactly these version-one fields:

- protocol version;
- canonical lowercase UUID pairing and connection identifiers;
- an unsigned decimal sequence number represented as a string;
- a Base64 payload of at most 32 KiB; and
- an HMAC-SHA256 authentication tag.

The tag covers a domain separator and length-prefixed version, pairing identifier, connection
identifier, canonical sequence, and exact payload bytes. Pairing and connection identifiers are
opaque random values. The verifier is bound to exactly one pairing and connection, requires at
least 256 bits of shared-secret material, verifies authentication before decoding Chrome payload
JSON, and accepts only a sequence greater than the last authenticated sequence. An authenticated
sequence is consumed before content filtering, so a signed poison payload cannot be replayed for
repeated parsing work. Rotation or reconnect gets a newly provisioned connection identifier; the
future provisioning slice stores its secret only in Keychain.

The version-one payload has a closed key set: incognito state, optional title, separate scheme,
host and percent-encoded path fields, navigation kind, tab-event kind, active/pinned booleans, and
audible/muted booleans. A complete URL is deliberately not a protocol field. Unknown keys fail
closed. In particular, URL, query, fragment, user-info, port, body, form, and HTML keys are not part
of the protocol. An incognito marker must be the payload's only key; the bridge does not cast,
normalize, or copy any optional content field and emits only a zero-content `incognitoSuppressed`
fact. A content-bearing incognito payload is a protocol violation and yields no fact.

For ordinary contexts, only `http` and `https` schemes are admitted. Because a complete URL is
never accepted, query, fragment, user-info and port data cannot enter the authenticated payload
contract. Host names are lowercased, trailing-dot normalized, ASCII-label validated, and bounded
to DNS limits. The percent-encoded path rejects raw query/fragment delimiters and remains bounded
without decoding. Canonical paths are preserved byte-for-byte, including a trailing slash; empty
interior segments and literal `.` or `..` segments fail closed instead of being silently rewritten
into a different objective path fact. Titles are control-free,
whitespace-normalized, and bounded incrementally to 256 UTF-8 bytes. Every free-form URL/title first
crosses a 4,096-scalar inspection budget.

The only public output is the non-Codable `ChromeContextFact`: receipt time, bounded filtered title,
query-free web location, closed navigation and tab-event values, ephemeral tab state without stable
tab/window identifiers, audio booleans, and a closed disposition. Raw envelopes, raw payloads,
pairing/connection wire values, the verifier, and signing/test codecs remain module-internal and are
not Codable. This fact is volatile; persistence or provider transfer requires the later shared
privacy gate and a separately reviewed projection.

## Alternatives considered

- **Trust Native Messaging because it is local:** rejected because framing and manifest routing do
  not prove that a message belongs to the current Dayday pairing or connection.
- **Authenticate only the payload:** rejected because identifiers, version, and sequence would
  remain malleable.
- **Put a complete URL in the public fact and redact later:** rejected because later redaction
  cannot undo a query/fragment archive or accidental diagnostic output.
- **Assign stable tab/window identifiers:** rejected because v0.1 needs transitions, not a
  reconstructable long-lived browser topology.
- **Allow arbitrary navigation/event strings:** rejected because unknown semantics could silently
  expand collection without a protocol review.
- **Represent authentication failures as browser facts:** rejected because rejected bytes are not
  objective user context and must not enter the activity timeline.

## Privacy and security impact

Unauthenticated, malformed, oversized, replayed, wrong-pairing, and wrong-connection messages yield
no public fact. Authentication failures contain no sensitive payload or tag in their error values
and the implementation performs no logging. Incognito yields a safe reason only. The public type
cannot represent query, fragment, user-info, port, body, form, HTML, stable tab identity, or extension
secret. HMAC prevents undetected tampering but does not make the extension a safe source by itself;
the extension must still omit prohibited values and the app's mandatory privacy gate remains final.

## Migration impact

There is no database migration and no persisted Chrome record in this slice. Protocol version one
is explicit. A future incompatible payload or authentication change adds a new version and retains
an intentionally bounded compatibility window rather than interpreting unknown fields.

## Rollout

1. Land the bounded frame decoder, authenticated verifier, privacy filter, and automated tests.
2. Add Keychain-backed pairing/rotation and an unpacked Chrome extension/native host without
   exposing secrets in settings, logs, backups, or exports.
3. Compose the bridge only while Chrome collection consent and lifecycle admission are active;
   disconnecting must not stop non-Chrome collectors.
4. Add site exclusions and the common R06 privacy gate before defining a persisted event projection.
5. On the user's Mac, validate install/reconnect, Chrome upgrade behavior, tab activation,
   navigation, audio changes, incognito suppression, credential rotation, and host disconnect before
   A14 acceptance.
