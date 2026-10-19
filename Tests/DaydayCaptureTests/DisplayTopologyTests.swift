import Testing
@testable import DaydayCapture

struct DisplayTopologyTests {
    @Test
    func enumerationOrderDoesNotChangeTopologyOrRevision() {
        let primary = descriptor(runtimeID: 7, x: 0, isMain: true)
        let secondary = descriptor(runtimeID: 42, x: 1_920)

        let forward = DisplayTopology(displays: [primary, secondary])
        let reversed = DisplayTopology(displays: [secondary, primary])

        #expect(forward == reversed)
        #expect(forward.revision == reversed.revision)
        #expect(forward.displays.map(\.runtimeID) == [7, 42])
    }

    @Test
    func layoutChangeProducesANewRevision() {
        let initial = DisplayTopology(displays: [
            descriptor(runtimeID: 7, x: 0, isMain: true),
            descriptor(runtimeID: 42, x: 1_920)
        ])
        let rearranged = DisplayTopology(displays: [
            descriptor(runtimeID: 7, x: 0, isMain: true),
            descriptor(runtimeID: 42, x: -1_920)
        ])

        #expect(initial != rearranged)
        #expect(initial.revision != rearranged.revision)
    }

    @Test
    func mirroringChangeProducesANewRevision() {
        let extended = DisplayTopology(displays: [descriptor(runtimeID: 42)])
        let mirrored = DisplayTopology(displays: [
            descriptor(runtimeID: 42, mirrorSourceRuntimeID: 7)
        ])

        #expect(extended.revision != mirrored.revision)
    }

    @Test
    func revisionIsDeterministicForAnEmptyTopology() {
        let first = DisplayTopology(displays: [])
        let second = DisplayTopology(displays: [])

        #expect(first == second)
        #expect(first.revision.rawValue == second.revision.rawValue)
        #expect(first.revision.rawValue != 0)
    }

    @Test
    func signedZeroHasCanonicalTopologySemantics() {
        let positive = DisplayTopology(displays: [descriptor(runtimeID: 7, x: 0.0)])
        let negative = DisplayTopology(displays: [descriptor(runtimeID: 7, x: -0.0)])

        #expect(positive == negative)
        #expect(positive.revision == negative.revision)
    }

    @Test
    func duplicateRuntimeIDsStillNormalizeIndependentlyOfInputOrder() {
        let left = descriptor(runtimeID: 7, x: -1_920)
        let right = descriptor(runtimeID: 7, x: 1_920)

        let forward = DisplayTopology(displays: [left, right])
        let reversed = DisplayTopology(displays: [right, left])

        #expect(forward == reversed)
        #expect(forward.revision == reversed.revision)
    }

    @Test
    func unavailableMetadataRemainsUnknownInsteadOfZero() {
        let unknown = DisplayDescriptor(
            runtimeID: 7,
            hardwareHint: DisplayHardwareHint(
                vendorNumber: nil,
                modelNumber: nil,
                serialNumber: nil
            ),
            bounds: DisplayBounds(x: 0, y: 0, width: 1_920, height: 1_080),
            pixelSize: nil,
            rotationDegrees: 0,
            isMain: true,
            isBuiltIn: false,
            mirrorSourceRuntimeID: nil
        )

        #expect(unknown.hardwareHint.vendorNumber == nil)
        #expect(unknown.hardwareHint.modelNumber == nil)
        #expect(unknown.pixelSize == nil)
        #expect(DisplayTopology(displays: [unknown]).displays == [unknown])
    }

    private func descriptor(
        runtimeID: UInt32,
        x: Double = 0,
        isMain: Bool = false,
        mirrorSourceRuntimeID: UInt32? = nil
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            runtimeID: runtimeID,
            hardwareHint: DisplayHardwareHint(
                vendorNumber: 1_552,
                modelNumber: 9_001,
                serialNumber: runtimeID
            ),
            bounds: DisplayBounds(x: x, y: 0, width: 1_920, height: 1_080),
            pixelSize: DisplayPixelSize(width: 3_840, height: 2_160),
            rotationDegrees: 0,
            isMain: isMain,
            isBuiltIn: runtimeID == 7,
            mirrorSourceRuntimeID: mirrorSourceRuntimeID
        )
    }
}
