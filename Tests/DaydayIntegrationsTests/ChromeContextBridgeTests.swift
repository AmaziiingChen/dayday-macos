import Foundation
import Testing
@testable import DaydayIntegrations

@Suite("Chrome context bridge")
struct ChromeContextBridgeTests {
    private let pairing = ChromePairingIdentifier(
        rawValue: UUID(uuidString: "BB387534-5203-4F8F-BE8D-B0AD135FFCE5")!
    )
    private let connection = ChromeConnectionIdentifier(
        rawValue: UUID(uuidString: "0512355D-B415-4D4C-99D3-0FEA12059D9F")!
    )
    private let secret = Data(repeating: 0xA7, count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("native-message decoder accepts partial and coalesced little-endian frames")
    func nativeMessageFramingIsStreaming() throws {
        let first = try ChromeNativeMessageFrameEncoder.encode(Data("one".utf8))
        let second = try ChromeNativeMessageFrameEncoder.encode(Data("two".utf8))
        var decoder = ChromeNativeMessageFrameDecoder(maximumFrameBytes: 32)

        #expect(try decoder.append(first.prefix(2)).isEmpty)
        var remainder = Data(first.dropFirst(2))
        remainder.append(second)
        let frames = try decoder.append(remainder)

        #expect(frames == [Data("one".utf8), Data("two".utf8)])
    }

    @Test("oversized declared length fails before payload buffering")
    func oversizedFrameFailsClosed() {
        var decoder = ChromeNativeMessageFrameDecoder(maximumFrameBytes: 8)
        let oversizedHeader = Data([9, 0, 0, 0])

        #expect(throws: ChromeNativeMessageError.oversizedFrame) {
            _ = try decoder.append(oversizedHeader)
        }
    }

    @Test("authenticated context exposes only bounded normalized objective facts")
    func authenticatedContextIsSanitized() async throws {
        let bridge = makeBridge()
        let payload = try json([
            "incognito": false,
            "title": "  Roadmap\n\u{7}" + String(repeating: "界", count: 200),
            "scheme": "HTTPS",
            "host": "Example.COM.",
            "path": "/a/c",
            "navigation": "typed",
            "tabEvent": "navigated",
            "activeTab": true,
            "pinned": false,
            "audible": true,
            "muted": false,
        ])

        let fact = try await bridge.accept(envelope(sequence: 1, payload: payload))

        #expect(fact.receivedAt == now)
        #expect(fact.disposition == .available)
        #expect(fact.title?.value.hasPrefix("Roadmap") == true)
        #expect((fact.title?.value.utf8.count ?? 0) <= 256)
        #expect(fact.title?.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false)
        #expect(fact.location?.scheme == .https)
        #expect(fact.location?.host.value == "example.com")
        #expect(fact.location?.path.value == "/a/c")
        #expect(fact.navigation == .typed)
        #expect(fact.tab?.event == .navigated)
        #expect(fact.tab?.isActive == true)
        #expect(fact.tab?.isPinned == false)
        #expect(fact.isAudible == true)
        #expect(fact.isMuted == false)
    }

    @Test("query fragment full URL user-info and port are not protocol fields")
    func forbiddenURLComponentsCannotEnterProtocol() async throws {
        let bridge = makeBridge()
        let safePayload = try standardPayload(path: "/path")

        let fact = try await bridge.accept(envelope(sequence: 1, payload: safePayload))

        #expect(fact.location?.host.value == "example.com")
        #expect(fact.location?.path.value == "/path")

        for (offset, forbiddenKey) in ["url", "query", "fragment", "userInfo", "port"].enumerated() {
            var object = standardPayloadObject()
            object[forbiddenKey] = "must never enter the bridge"
            await #expect(throws: ChromeNativeMessageError.malformedPayload) {
                _ = try await bridge.accept(
                    envelope(sequence: UInt64(offset + 2), payload: try json(object))
                )
            }
        }
    }

    @Test("incognito is always a zero-content fact")
    func incognitoIsZeroContent() async throws {
        let bridge = makeBridge()
        let payload = try json([
            "incognito": true,
        ])

        let fact = try await bridge.accept(envelope(sequence: 1, payload: payload))

        #expect(fact.disposition == .incognitoSuppressed)
        #expect(fact.title == nil)
        #expect(fact.location == nil)
        #expect(fact.navigation == nil)
        #expect(fact.tab == nil)
        #expect(fact.isAudible == nil)
        #expect(fact.isMuted == nil)
    }

    @Test("an incognito marker carrying any context is rejected")
    func incognitoContentFailsClosed() async throws {
        let payload = try json([
            "incognito": true,
            "title": "must never enter an incognito fact",
        ])
        await #expect(throws: ChromeNativeMessageError.malformedPayload) {
            _ = try await makeBridge().accept(envelope(sequence: 1, payload: payload))
        }
    }

    @Test("unknown payload fields including body form and HTML fail closed")
    func forbiddenPayloadFieldsFailClosed() async throws {
        for forbiddenKey in ["query", "fragment", "body", "form", "html"] {
            let bridge = makeBridge()
            var object = standardPayloadObject()
            object[forbiddenKey] = "must never escape"
            let payload = try json(object)

            await #expect(throws: ChromeNativeMessageError.malformedPayload) {
                _ = try await bridge.accept(envelope(sequence: 1, payload: payload))
            }
        }
    }

    @Test("tampering and wrong pairing or connection are rejected")
    func authenticationAndIdentifiersFailClosed() async throws {
        let payload = try standardPayload()
        let valid = envelope(sequence: 1, payload: payload)
        let object = try #require(
            try JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var tampered = object
        tampered["payload"] = Data("{}".utf8).base64EncodedString()
        let tamperedData = try json(tampered)

        await #expect(throws: ChromeNativeMessageError.invalidAuthentication) {
            _ = try await makeBridge().accept(tamperedData)
        }

        let otherPairing = ChromePairingIdentifier()
        let wrongPairingEnvelope = try ChromeContextTestEnvelopeFactory.encode(
            pairingIdentifier: otherPairing,
            connectionIdentifier: connection,
            sequence: 1,
            payload: payload,
            sharedSecret: secret
        )
        await #expect(throws: ChromeNativeMessageError.pairingMismatch) {
            _ = try await makeBridge().accept(wrongPairingEnvelope)
        }

        let otherConnection = ChromeConnectionIdentifier()
        let wrongConnectionEnvelope = try ChromeContextTestEnvelopeFactory.encode(
            pairingIdentifier: pairing,
            connectionIdentifier: otherConnection,
            sequence: 1,
            payload: payload,
            sharedSecret: secret
        )
        await #expect(throws: ChromeNativeMessageError.connectionMismatch) {
            _ = try await makeBridge().accept(wrongConnectionEnvelope)
        }
    }

    @Test("sequence is strictly monotonic and authenticated malformed messages are consumed")
    func replayProtectionIsMonotonic() async throws {
        let bridge = makeBridge()
        let payload = try standardPayload()

        _ = try await bridge.accept(envelope(sequence: 10, payload: payload))
        await #expect(throws: ChromeNativeMessageError.replayedSequence) {
            _ = try await bridge.accept(envelope(sequence: 10, payload: payload))
        }
        await #expect(throws: ChromeNativeMessageError.replayedSequence) {
            _ = try await bridge.accept(envelope(sequence: 9, payload: payload))
        }
        _ = try await bridge.accept(envelope(sequence: 12, payload: payload))

        let malformed = Data("{}".utf8)
        await #expect(throws: ChromeNativeMessageError.malformedPayload) {
            _ = try await bridge.accept(envelope(sequence: 13, payload: malformed))
        }
        await #expect(throws: ChromeNativeMessageError.replayedSequence) {
            _ = try await bridge.accept(envelope(sequence: 13, payload: payload))
        }
    }

    @Test("malformed envelopes and unsupported versions fail closed")
    func malformedEnvelopeFailsClosed() async throws {
        let bridge = makeBridge()
        await #expect(throws: ChromeNativeMessageError.malformedEnvelope) {
            _ = try await bridge.accept(Data("not-json".utf8))
        }

        let payload = try standardPayload()
        let valid = envelope(sequence: 1, payload: payload)
        var object = try #require(
            try JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["protocolVersion"] = 2
        await #expect(throws: ChromeNativeMessageError.unsupportedProtocolVersion) {
            _ = try await bridge.accept(try json(object))
        }
    }

    @Test("unsupported schemes and oversized raw fields produce no fact")
    func unsafeLocationsAndOversizedInputFailClosed() async throws {
        let bridge = makeBridge()
        let filePayload = try standardPayload(scheme: "file", path: "/Users/person/secret.txt")
        await #expect(throws: ChromeNativeMessageError.unsupportedLocation) {
            _ = try await bridge.accept(envelope(sequence: 1, payload: filePayload))
        }

        let hugeURLPayload = try standardPayload(path: "/" + String(repeating: "a", count: 5_000))
        await #expect(throws: ChromeNativeMessageError.unsupportedLocation) {
            _ = try await bridge.accept(envelope(sequence: 2, payload: hugeURLPayload))
        }
    }

    @Test("canonical path preserves trailing slash while ambiguous segments fail closed")
    func pathsAreNeverSilentlyRewritten() async throws {
        let trailingSlashFact = try await makeBridge().accept(
            envelope(sequence: 1, payload: try standardPayload(path: "/a/"))
        )
        #expect(trailingSlashFact.location?.path.value == "/a/")

        for path in ["/a//b", "/a/./", "/a/b/.."] {
            await #expect(throws: ChromeNativeMessageError.unsupportedLocation) {
                _ = try await makeBridge().accept(
                    envelope(sequence: 1, payload: try standardPayload(path: path))
                )
            }
        }
    }

    private func makeBridge() -> ChromeAuthenticatedContextBridge {
        ChromeAuthenticatedContextBridge(
            pairingIdentifier: pairing,
            connectionIdentifier: connection,
            sharedSecret: secret,
            clock: { now }
        )
    }

    private func envelope(sequence: UInt64, payload: Data) -> Data {
        try! ChromeContextTestEnvelopeFactory.encode(
            pairingIdentifier: pairing,
            connectionIdentifier: connection,
            sequence: sequence,
            payload: payload,
            sharedSecret: secret
        )
    }

    private func standardPayload(
        scheme: String = "https",
        host: String = "example.com",
        path: String = "/"
    ) throws -> Data {
        try json(standardPayloadObject(scheme: scheme, host: host, path: path))
    }

    private func standardPayloadObject(
        scheme: String = "https",
        host: String = "example.com",
        path: String = "/"
    ) -> [String: Any] {
        [
            "incognito": false,
            "title": "Example",
            "scheme": scheme,
            "host": host,
            "path": path,
            "navigation": "link",
            "tabEvent": "updated",
            "activeTab": true,
            "pinned": false,
            "audible": false,
            "muted": false,
        ]
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
