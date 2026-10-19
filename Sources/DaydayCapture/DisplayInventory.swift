import CoreGraphics
import Foundation

public struct DisplayBounds: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DisplayPixelSize: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Hardware numbers exposed by CoreGraphics. These are useful reconciliation hints, not a
/// guaranteed permanent display identity: adapters, docks, mirroring, and OS behavior may make
/// them absent or non-unique.
public struct DisplayHardwareHint: Sendable, Hashable {
    public let vendorNumber: UInt32?
    public let modelNumber: UInt32?
    public let serialNumber: UInt32?

    public init(vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?) {
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }
}

/// An objective description of one online display at enumeration time.
///
/// `runtimeID` is stable enough for an active macOS display session but is not a persistent user
/// or device identifier. Consumers must tolerate it changing after reboot or topology changes.
public struct DisplayDescriptor: Sendable, Hashable {
    public let runtimeID: UInt32
    public let hardwareHint: DisplayHardwareHint
    public let bounds: DisplayBounds
    public let pixelSize: DisplayPixelSize?
    public let rotationDegrees: Double
    public let isMain: Bool
    public let isBuiltIn: Bool
    public let mirrorSourceRuntimeID: UInt32?

    public init(
        runtimeID: UInt32,
        hardwareHint: DisplayHardwareHint,
        bounds: DisplayBounds,
        pixelSize: DisplayPixelSize?,
        rotationDegrees: Double,
        isMain: Bool,
        isBuiltIn: Bool,
        mirrorSourceRuntimeID: UInt32?
    ) {
        self.runtimeID = runtimeID
        self.hardwareHint = hardwareHint
        self.bounds = bounds
        self.pixelSize = pixelSize
        self.rotationDegrees = rotationDegrees
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.mirrorSourceRuntimeID = mirrorSourceRuntimeID
    }
}

public enum DisplayInventoryError: Error, Sendable, Equatable {
    case coreGraphicsFailure(code: Int32)
}

public protocol DisplayInventoryProviding: Sendable {
    /// Enumerates metadata for online displays. It does not request screen access or capture pixels.
    func onlineDisplays() throws -> [DisplayDescriptor]
}

/// A metadata-only CoreGraphics inventory. No image surface or window content is requested.
public struct CoreGraphicsDisplayInventory: DisplayInventoryProviding {
    public init() {}

    public func onlineDisplays() throws -> [DisplayDescriptor] {
        var displayCount: UInt32 = 0
        try Self.check(CGGetOnlineDisplayList(0, nil, &displayCount))

        guard displayCount > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var writtenCount: UInt32 = 0
        try displayIDs.withUnsafeMutableBufferPointer { buffer in
            try Self.check(
                CGGetOnlineDisplayList(displayCount, buffer.baseAddress, &writtenCount)
            )
        }

        return displayIDs.prefix(Int(writtenCount)).map(Self.describe)
    }

    private static func check(_ error: CGError) throws {
        guard error == .success else {
            throw DisplayInventoryError.coreGraphicsFailure(code: error.rawValue)
        }
    }

    private static func describe(_ displayID: CGDirectDisplayID) -> DisplayDescriptor {
        let bounds = CGDisplayBounds(displayID)
        let mode = CGDisplayCopyDisplayMode(displayID)
        let mirrorSource = CGDisplayMirrorsDisplay(displayID)
        let vendorNumber = CGDisplayVendorNumber(displayID)
        let modelNumber = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        return DisplayDescriptor(
            runtimeID: displayID,
            hardwareHint: DisplayHardwareHint(
                vendorNumber: vendorNumber == 0 ? nil : vendorNumber,
                modelNumber: modelNumber == 0 ? nil : modelNumber,
                serialNumber: serialNumber == 0 ? nil : serialNumber
            ),
            bounds: DisplayBounds(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            ),
            pixelSize: mode.map {
                DisplayPixelSize(width: $0.pixelWidth, height: $0.pixelHeight)
            },
            rotationDegrees: CGDisplayRotation(displayID),
            isMain: CGDisplayIsMain(displayID) != 0,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            mirrorSourceRuntimeID: mirrorSource == kCGNullDirectDisplay ? nil : mirrorSource
        )
    }
}
