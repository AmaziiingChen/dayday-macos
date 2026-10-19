import CryptoKit
import Foundation

/// Why an authenticated Chrome message produced no browser content.
public enum ChromeContextDisposition: Equatable, Hashable, Sendable {
    case available
    case incognitoSuppressed
}

/// Chrome navigation transition reported by the extension. It describes the
/// transition only; no request, response, or form content is represented.
public enum ChromeNavigationKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case link
    case typed
    case autoBookmark
    case autoSubframe
    case manualSubframe
    case generated
    case startPage
    case formSubmit
    case reload
    case keyword
    case keywordGenerated
    case other
}

public enum ChromeWebScheme: String, CaseIterable, Equatable, Hashable, Sendable {
    case http
    case https
}

public enum ChromeTabEventKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case activated
    case updated
    case navigated
    case audioChanged
}

/// A field that has crossed the Chrome bridge's field-specific input and UTF-8
/// output bounds. It has no public initializer.
public struct PrivacyFilteredChromeText: Equatable, Hashable, Sendable {
    public let value: String

    fileprivate init(value: String) {
        self.value = value
    }
}

/// A query-, fragment-, user-info-, and port-free web location.
public struct ChromeWebLocationFact: Equatable, Hashable, Sendable {
    public let scheme: ChromeWebScheme
    public let host: PrivacyFilteredChromeText
    public let path: PrivacyFilteredChromeText

    fileprivate init(
        scheme: ChromeWebScheme,
        host: PrivacyFilteredChromeText,
        path: PrivacyFilteredChromeText
    ) {
        self.scheme = scheme
        self.host = host
        self.path = path
    }
}

/// Volatile tab state without a stable tab/window identifier.
public struct ChromeTabFact: Equatable, Hashable, Sendable {
    public let event: ChromeTabEventKind
    public let isActive: Bool
    public let isPinned: Bool

    fileprivate init(event: ChromeTabEventKind, isActive: Bool, isPinned: Bool) {
        self.event = event
        self.isActive = isActive
        self.isPinned = isPinned
    }
}

/// Volatile, authenticated, privacy-filtered browser context.
///
/// It is deliberately not Codable. Persistence or model-provider transfer
/// requires a later, separately reviewed projection.
public struct ChromeContextFact: Equatable, Hashable, Sendable {
    public let receivedAt: Date
    public let title: PrivacyFilteredChromeText?
    public let location: ChromeWebLocationFact?
    public let navigation: ChromeNavigationKind?
    public let tab: ChromeTabFact?
    public let isAudible: Bool?
    public let isMuted: Bool?
    public let disposition: ChromeContextDisposition

    fileprivate init(
        receivedAt: Date,
        title: PrivacyFilteredChromeText? = nil,
        location: ChromeWebLocationFact? = nil,
        navigation: ChromeNavigationKind? = nil,
        tab: ChromeTabFact? = nil,
        isAudible: Bool? = nil,
        isMuted: Bool? = nil,
        disposition: ChromeContextDisposition
    ) {
        self.receivedAt = receivedAt
        self.title = title
        self.location = location
        self.navigation = navigation
        self.tab = tab
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.disposition = disposition
    }
}

/// Random identifiers are intentionally opaque outside this module. The native
/// host packaging slice will provision their wire representation.
struct ChromePairingIdentifier: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

struct ChromeConnectionIdentifier: Equatable, Hashable, Sendable {
    fileprivate let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

enum ChromeNativeMessageError: Error, Equatable, Sendable {
    case oversizedFrame
    case malformedEnvelope
    case unsupportedProtocolVersion
    case pairingMismatch
    case connectionMismatch
    case invalidAuthentication
    case replayedSequence
    case malformedPayload
    case unsupportedLocation
}

/// Streaming decoder for Chrome native-messaging's UInt32 little-endian frame.
/// A protocol violation clears buffered bytes and the caller must establish a
/// fresh native-messaging connection.
struct ChromeNativeMessageFrameDecoder: Sendable {
    static let defaultMaximumFrameBytes = 64 * 1_024

    private let maximumFrameBytes: Int
    private var buffer = Data()

    init(maximumFrameBytes: Int = defaultMaximumFrameBytes) {
        precondition(maximumFrameBytes > 0 && maximumFrameBytes <= Int(UInt32.max))
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)

        var frames: [Data] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let declaredLength = Int(
                UInt32(buffer[buffer.startIndex])
                    | (UInt32(buffer[buffer.startIndex + 1]) << 8)
                    | (UInt32(buffer[buffer.startIndex + 2]) << 16)
                    | (UInt32(buffer[buffer.startIndex + 3]) << 24)
            )
            guard declaredLength > 0, declaredLength <= maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw ChromeNativeMessageError.oversizedFrame
            }
            let framedLength = MemoryLayout<UInt32>.size + declaredLength
            guard buffer.count >= framedLength else {
                guard buffer.count <= maximumFrameBytes + MemoryLayout<UInt32>.size else {
                    buffer.removeAll(keepingCapacity: false)
                    throw ChromeNativeMessageError.oversizedFrame
                }
                break
            }
            frames.append(buffer.subdata(in: 4..<framedLength))
            buffer.removeSubrange(0..<framedLength)
        }
        return frames
    }
}

enum ChromeNativeMessageFrameEncoder {
    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty,
              payload.count <= ChromeNativeMessageFrameDecoder.defaultMaximumFrameBytes else {
            throw ChromeNativeMessageError.oversizedFrame
        }
        let length = UInt32(payload.count)
        var result = Data([
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24),
        ])
        result.append(payload)
        return result
    }
}

/// Raw authenticated-envelope storage remains internal and is not Codable.
struct RawChromeAuthenticatedEnvelope: Sendable {
    let protocolVersion: Int
    let pairingIdentifier: String
    let connectionIdentifier: String
    let sequence: UInt64
    let payload: Data
    let authenticationTag: Data
}

/// Raw extension values remain internal and are released after one filter call.
struct RawChromeContextPayload: Sendable {
    let incognito: Bool
    let title: String?
    let scheme: String?
    let host: String?
    let path: String?
    let navigation: String?
    let tabEvent: String?
    let activeTab: Bool?
    let pinned: Bool?
    let audible: Bool?
    let muted: Bool?
}

private enum ChromeBridgeLimits {
    static let maximumIdentifierBytes = 36
    static let maximumSequenceDigits = 20
    static let maximumPayloadBytes = 32 * 1_024
    static let maximumInputScalars = 4_096
    static let maximumTitleBytes = 256
    static let maximumHostBytes = 253
    static let maximumPathBytes = 512
}

private enum ChromeAuthenticatedEnvelopeCodec {
    static let protocolVersion = 1
    private static let allowedKeys: Set<String> = [
        "protocolVersion",
        "pairingIdentifier",
        "connectionIdentifier",
        "sequence",
        "payload",
        "authenticationTag",
    ]

    static func decode(_ data: Data) throws -> RawChromeAuthenticatedEnvelope {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ChromeNativeMessageError.malformedEnvelope
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == allowedKeys,
              let version = dictionary["protocolVersion"] as? Int,
              let pairing = dictionary["pairingIdentifier"] as? String,
              let connection = dictionary["connectionIdentifier"] as? String,
              let sequenceText = dictionary["sequence"] as? String,
              let payloadText = dictionary["payload"] as? String,
              let authenticationText = dictionary["authenticationTag"] as? String else {
            throw ChromeNativeMessageError.malformedEnvelope
        }
        guard version == protocolVersion else {
            throw ChromeNativeMessageError.unsupportedProtocolVersion
        }
        guard pairing.utf8.count == ChromeBridgeLimits.maximumIdentifierBytes,
              connection.utf8.count == ChromeBridgeLimits.maximumIdentifierBytes,
              UUID(uuidString: pairing)?.uuidString.lowercased() == pairing,
              UUID(uuidString: connection)?.uuidString.lowercased() == connection,
              !sequenceText.isEmpty,
              sequenceText.utf8.count <= ChromeBridgeLimits.maximumSequenceDigits,
              sequenceText == "0" || sequenceText.first != "0",
              sequenceText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let sequence = UInt64(sequenceText),
              let payload = Data(base64Encoded: payloadText, options: []),
              !payload.isEmpty,
              payload.count <= ChromeBridgeLimits.maximumPayloadBytes,
              let authenticationTag = Data(base64Encoded: authenticationText, options: []),
              authenticationTag.count == SHA256.byteCount else {
            throw ChromeNativeMessageError.malformedEnvelope
        }
        return RawChromeAuthenticatedEnvelope(
            protocolVersion: version,
            pairingIdentifier: pairing,
            connectionIdentifier: connection,
            sequence: sequence,
            payload: payload,
            authenticationTag: authenticationTag
        )
    }

    static func encode(
        pairingIdentifier: ChromePairingIdentifier,
        connectionIdentifier: ChromeConnectionIdentifier,
        sequence: UInt64,
        payload: Data,
        sharedSecret: Data
    ) throws -> Data {
        guard !payload.isEmpty, payload.count <= ChromeBridgeLimits.maximumPayloadBytes else {
            throw ChromeNativeMessageError.malformedPayload
        }
        let pairing = pairingIdentifier.rawValue.uuidString.lowercased()
        let connection = connectionIdentifier.rawValue.uuidString.lowercased()
        let sequenceText = String(sequence)
        let tag = authenticationTag(
            version: protocolVersion,
            pairing: pairing,
            connection: connection,
            sequence: sequenceText,
            payload: payload,
            sharedSecret: sharedSecret
        )
        let object: [String: Any] = [
            "protocolVersion": protocolVersion,
            "pairingIdentifier": pairing,
            "connectionIdentifier": connection,
            "sequence": sequenceText,
            "payload": payload.base64EncodedString(),
            "authenticationTag": tag.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func isAuthenticated(_ envelope: RawChromeAuthenticatedEnvelope, sharedSecret: Data) -> Bool {
        let bytes = authenticatedBytes(
            version: envelope.protocolVersion,
            pairing: envelope.pairingIdentifier,
            connection: envelope.connectionIdentifier,
            sequence: String(envelope.sequence),
            payload: envelope.payload
        )
        return HMAC<SHA256>.isValidAuthenticationCode(
            envelope.authenticationTag,
            authenticating: bytes,
            using: SymmetricKey(data: sharedSecret)
        )
    }

    private static func authenticationTag(
        version: Int,
        pairing: String,
        connection: String,
        sequence: String,
        payload: Data,
        sharedSecret: Data
    ) -> Data {
        let bytes = authenticatedBytes(
            version: version,
            pairing: pairing,
            connection: connection,
            sequence: sequence,
            payload: payload
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: bytes,
            using: SymmetricKey(data: sharedSecret)
        )
        return Data(code)
    }

    private static func authenticatedBytes(
        version: Int,
        pairing: String,
        connection: String,
        sequence: String,
        payload: Data
    ) -> Data {
        var result = Data("dayday.chrome.native-message\u{0}".utf8)
        for component in [
            Data(String(version).utf8),
            Data(pairing.utf8),
            Data(connection.utf8),
            Data(sequence.utf8),
            payload,
        ] {
            appendLengthPrefixed(component, to: &result)
        }
        return result
    }

    private static func appendLengthPrefixed(_ data: Data, to output: inout Data) {
        let length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: length) { output.append(contentsOf: $0) }
        output.append(data)
    }
}

private enum ChromeContextPayloadCodec {
    private static let allowedKeys: Set<String> = [
        "incognito",
        "title",
        "scheme",
        "host",
        "path",
        "navigation",
        "tabEvent",
        "activeTab",
        "pinned",
        "audible",
        "muted",
    ]

    static func decode(_ data: Data) throws -> RawChromeContextPayload {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ChromeNativeMessageError.malformedPayload
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys),
              let incognito = dictionary["incognito"] as? Bool else {
            throw ChromeNativeMessageError.malformedPayload
        }

        // Incognito messages are intentionally content-agnostic. No optional
        // string is cast, normalized, or copied before the zero-content result.
        if incognito {
            guard Set(dictionary.keys) == ["incognito"] else {
                throw ChromeNativeMessageError.malformedPayload
            }
            return RawChromeContextPayload(
                incognito: true,
                title: nil,
                scheme: nil,
                host: nil,
                path: nil,
                navigation: nil,
                tabEvent: nil,
                activeTab: nil,
                pinned: nil,
                audible: nil,
                muted: nil
            )
        }

        guard dictionary.keys.contains("scheme"),
              dictionary.keys.contains("host"),
              dictionary.keys.contains("path"),
              dictionary.keys.contains("navigation"),
              dictionary.keys.contains("tabEvent"),
              dictionary.keys.contains("activeTab"),
              dictionary.keys.contains("pinned"),
              dictionary.keys.contains("audible"),
              dictionary.keys.contains("muted"),
              let scheme = dictionary["scheme"] as? String,
              let host = dictionary["host"] as? String,
              let path = dictionary["path"] as? String,
              let navigation = dictionary["navigation"] as? String,
              let tabEvent = dictionary["tabEvent"] as? String,
              let activeTab = dictionary["activeTab"] as? Bool,
              let pinned = dictionary["pinned"] as? Bool,
              let audible = dictionary["audible"] as? Bool,
              let muted = dictionary["muted"] as? Bool,
              dictionary["title"] == nil || dictionary["title"] is String else {
            throw ChromeNativeMessageError.malformedPayload
        }
        return RawChromeContextPayload(
            incognito: false,
            title: dictionary["title"] as? String,
            scheme: scheme,
            host: host,
            path: path,
            navigation: navigation,
            tabEvent: tabEvent,
            activeTab: activeTab,
            pinned: pinned,
            audible: audible,
            muted: muted
        )
    }
}

private enum ChromeContextPrivacyFilter {
    static func filter(_ payload: RawChromeContextPayload, receivedAt: Date) throws -> ChromeContextFact {
        if payload.incognito {
            return ChromeContextFact(receivedAt: receivedAt, disposition: .incognitoSuppressed)
        }
        guard let rawScheme = admitted(payload.scheme),
              let rawHost = admitted(payload.host),
              let rawPath = admitted(payload.path),
              let navigationText = payload.navigation,
              let navigation = ChromeNavigationKind(rawValue: navigationText),
              let tabEventText = payload.tabEvent,
              let tabEvent = ChromeTabEventKind(rawValue: tabEventText),
              let activeTab = payload.activeTab,
              let pinned = payload.pinned,
              let audible = payload.audible,
              let muted = payload.muted,
              let location = webLocation(scheme: rawScheme, host: rawHost, path: rawPath) else {
            throw ChromeNativeMessageError.unsupportedLocation
        }
        let title = filteredText(payload.title, maximumBytes: ChromeBridgeLimits.maximumTitleBytes)
        return ChromeContextFact(
            receivedAt: receivedAt,
            title: title,
            location: location,
            navigation: navigation,
            tab: ChromeTabFact(event: tabEvent, isActive: activeTab, isPinned: pinned),
            isAudible: audible,
            isMuted: muted,
            disposition: .available
        )
    }

    private static func admitted(_ value: String?) -> String? {
        guard let value else { return nil }
        var index = value.unicodeScalars.startIndex
        var count = 0
        while index != value.unicodeScalars.endIndex {
            guard count < ChromeBridgeLimits.maximumInputScalars else { return nil }
            value.unicodeScalars.formIndex(after: &index)
            count += 1
        }
        return value
    }

    private static func webLocation(
        scheme rawScheme: String,
        host rawHost: String,
        path rawPath: String
    ) -> ChromeWebLocationFact? {
        guard let scheme = ChromeWebScheme(rawValue: rawScheme.lowercased()),
              !rawHost.isEmpty else {
            return nil
        }
        let lowercasedHost = rawHost.lowercased()
        let hostValue = lowercasedHost.hasSuffix(".")
            ? String(lowercasedHost.dropLast())
            : lowercasedHost
        guard isSafeHost(hostValue),
              let host = exactFilteredText(hostValue, maximumBytes: ChromeBridgeLimits.maximumHostBytes),
              let path = normalizedPath(rawPath) else {
            return nil
        }
        return ChromeWebLocationFact(scheme: scheme, host: host, path: path)
    }

    private static func isSafeHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.utf8.count <= ChromeBridgeLimits.maximumHostBytes,
              !host.contains(".."),
              host.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
              }) else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty
                && label.utf8.count <= 63
                && label.first != "-"
                && label.last != "-"
        }
    }

    private static func normalizedPath(_ rawPath: String) -> PrivacyFilteredChromeText? {
        let path = rawPath.isEmpty ? "/" : rawPath
        guard admitted(path) != nil,
              path.first == "/",
              !path.contains("?"),
              !path.contains("#"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        guard path != "/" else {
            return exactFilteredText(path, maximumBytes: ChromeBridgeLimits.maximumPathBytes)
        }

        // The bridge reports objective path facts, so it must not silently turn
        // two distinct paths into one. Chrome must send an already canonical
        // percent-encoded path. Empty interior and dot segments fail closed;
        // a final empty segment is retained as the observable trailing slash.
        guard !path.contains("//") else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            let isRetainedTrailingSlash = component.isEmpty && index == components.index(before: components.endIndex)
            guard isRetainedTrailingSlash || (!component.isEmpty && component != "." && component != "..") else {
                return nil
            }
        }
        return exactFilteredText(path, maximumBytes: ChromeBridgeLimits.maximumPathBytes)
    }

    private static func exactFilteredText(
        _ value: String,
        maximumBytes: Int
    ) -> PrivacyFilteredChromeText? {
        guard admitted(value) != nil,
              !value.isEmpty,
              value.utf8.count <= maximumBytes else {
            return nil
        }
        return PrivacyFilteredChromeText(value: value)
    }

    private static func filteredText(
        _ rawValue: String?,
        maximumBytes: Int
    ) -> PrivacyFilteredChromeText? {
        guard let rawValue = admitted(rawValue) else { return nil }
        let pieces = rawValue
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let normalized = String(String.UnicodeScalarView(pieces))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var output = Data()
        for scalar in normalized.unicodeScalars {
            let bytes = String(scalar).utf8
            guard output.count + bytes.count <= maximumBytes else { break }
            output.append(contentsOf: bytes)
        }
        guard let value = String(data: output, encoding: .utf8), !value.isEmpty else { return nil }
        return PrivacyFilteredChromeText(value: value)
    }
}

/// Authenticates one native-messaging connection and rejects replayed sequence
/// numbers before any raw Chrome payload is decoded.
actor ChromeAuthenticatedContextBridge {
    private let pairingIdentifier: ChromePairingIdentifier
    private let connectionIdentifier: ChromeConnectionIdentifier
    private let sharedSecret: Data
    private let clock: @Sendable () -> Date
    private var lastAcceptedSequence: UInt64?

    init(
        pairingIdentifier: ChromePairingIdentifier,
        connectionIdentifier: ChromeConnectionIdentifier,
        sharedSecret: Data,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(sharedSecret.count >= 32)
        self.pairingIdentifier = pairingIdentifier
        self.connectionIdentifier = connectionIdentifier
        self.sharedSecret = sharedSecret
        self.clock = clock
    }

    func accept(_ envelopeData: Data) throws -> ChromeContextFact {
        let envelope = try ChromeAuthenticatedEnvelopeCodec.decode(envelopeData)
        guard ChromeAuthenticatedEnvelopeCodec.isAuthenticated(
            envelope,
            sharedSecret: sharedSecret
        ) else {
            throw ChromeNativeMessageError.invalidAuthentication
        }
        guard envelope.pairingIdentifier == pairingIdentifier.rawValue.uuidString.lowercased() else {
            throw ChromeNativeMessageError.pairingMismatch
        }
        guard envelope.connectionIdentifier == connectionIdentifier.rawValue.uuidString.lowercased() else {
            throw ChromeNativeMessageError.connectionMismatch
        }
        if let lastAcceptedSequence, envelope.sequence <= lastAcceptedSequence {
            throw ChromeNativeMessageError.replayedSequence
        }
        // Consume an authenticated sequence even when its payload is malformed,
        // preventing a signed poison message from being replayed for free work.
        lastAcceptedSequence = envelope.sequence

        let payload = try ChromeContextPayloadCodec.decode(envelope.payload)
        return try ChromeContextPrivacyFilter.filter(payload, receivedAt: clock())
    }
}

enum ChromeContextTestEnvelopeFactory {
    static func encode(
        pairingIdentifier: ChromePairingIdentifier,
        connectionIdentifier: ChromeConnectionIdentifier,
        sequence: UInt64,
        payload: Data,
        sharedSecret: Data
    ) throws -> Data {
        try ChromeAuthenticatedEnvelopeCodec.encode(
            pairingIdentifier: pairingIdentifier,
            connectionIdentifier: connectionIdentifier,
            sequence: sequence,
            payload: payload,
            sharedSecret: sharedSecret
        )
    }
}
