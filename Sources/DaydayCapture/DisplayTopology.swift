import Foundation

/// A deterministic, collision-possible token for detecting topology changes within capture
/// coordination. It is not a display identity and must not be used as a persistent primary key.
public struct DisplayTopologyRevision: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A normalized, immutable topology snapshot. Equality and revision are independent of the order
/// in which CoreGraphics happened to enumerate displays.
public struct DisplayTopology: Sendable, Equatable {
    public let displays: [DisplayDescriptor]
    public let revision: DisplayTopologyRevision

    public init(displays: [DisplayDescriptor]) {
        let normalized = displays.sorted { lhs, rhs in
            Self.encoded(lhs).lexicographicallyPrecedes(Self.encoded(rhs))
        }
        self.displays = normalized
        self.revision = Self.makeRevision(for: normalized)
    }

    private static func makeRevision(for displays: [DisplayDescriptor]) -> DisplayTopologyRevision {
        var digest = StableTopologyDigest()
        digest.append(UInt64(displays.count))

        for display in displays {
            for word in encoded(display) {
                digest.append(word)
            }
        }

        return DisplayTopologyRevision(rawValue: digest.value)
    }

    /// Encodes every public value so sorting is deterministic even for duplicate runtime IDs.
    /// Signed zero is canonicalized to preserve Swift's `Double` equality semantics.
    private static func encoded(_ display: DisplayDescriptor) -> [UInt64] {
        var words = [UInt64(display.runtimeID)]
        words.append(optional: display.hardwareHint.vendorNumber.map(UInt64.init))
        words.append(optional: display.hardwareHint.modelNumber.map(UInt64.init))
        words.append(optional: display.hardwareHint.serialNumber.map(UInt64.init))
        words.append(canonicalBits(display.bounds.x))
        words.append(canonicalBits(display.bounds.y))
        words.append(canonicalBits(display.bounds.width))
        words.append(canonicalBits(display.bounds.height))
        words.append(display.pixelSize == nil ? 0 : 1)
        if let pixelSize = display.pixelSize {
            words.append(UInt64(bitPattern: Int64(pixelSize.width)))
            words.append(UInt64(bitPattern: Int64(pixelSize.height)))
        }
        words.append(canonicalBits(display.rotationDegrees))
        words.append(display.isMain ? 1 : 0)
        words.append(display.isBuiltIn ? 1 : 0)
        words.append(optional: display.mirrorSourceRuntimeID.map(UInt64.init))
        return words
    }

    private static func canonicalBits(_ value: Double) -> UInt64 {
        value == 0 ? 0 : value.bitPattern
    }
}

private extension Array where Element == UInt64 {
    mutating func append(optional value: UInt64?) {
        append(value == nil ? 0 : 1)
        if let value { append(value) }
    }
}

/// A deterministic FNV-1a digest used only as a cheap change token. Topology equality continues to
/// compare the full value, so this digest is not treated as a unique or security-sensitive ID.
private struct StableTopologyDigest {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ value: UInt64) {
        var value = value
        for _ in 0..<8 {
            appendByte(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
    }

    mutating func append(_ value: Bool) {
        appendByte(value ? 1 : 0)
    }

    mutating func append(_ value: UInt64?) {
        appendByte(value == nil ? 0 : 1)
        if let value { append(value) }
    }

    private mutating func appendByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
}
