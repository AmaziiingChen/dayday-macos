import Testing
@testable import DaydayCapture

struct DisplayIdentityReconcilerTests {
    @Test
    func firstSnapshotAddsDisplaysAndAnUnchangedSnapshotRetainsThem() {
        var reconciler = DisplayIdentityReconciler()
        let topology = DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101, x: 0),
            descriptor(runtimeID: 42, serialNumber: 202, x: 1_920)
        ])

        let first = reconciler.reconcile(topology)
        let second = reconciler.reconcile(topology)

        #expect(first.topologyChanged)
        #expect(first.delta.added.count == 2)
        #expect(first.delta.removed.isEmpty)
        #expect(first.delta.retained.isEmpty)
        #expect(!second.topologyChanged)
        #expect(second.delta.added.isEmpty)
        #expect(second.delta.removed.isEmpty)
        #expect(second.delta.retained.map(\.id) == first.displays.map(\.id))
    }

    @Test
    func conflictingCompleteHardwareFactsRejectARecycledRuntimeID() throws {
        var reconciler = DisplayIdentityReconciler()
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101)
        ]))
        let originalID = try #require(first.displays.first?.id)

        let changed = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, vendorNumber: 9_999, modelNumber: 8_888, serialNumber: 707)
        ]))

        #expect(changed.displays.first?.id != originalID)
        #expect(changed.delta.retained.isEmpty)
        #expect(changed.delta.removed.map(\.id) == [originalID])
        #expect(changed.delta.added.count == 1)
        #expect(changed.topologyChanged)
    }

    @Test
    func adjacentUniqueRuntimeIDCanRetainWhenHardwareFactsAreUnavailable() throws {
        var reconciler = DisplayIdentityReconciler()
        let unavailable = DisplayHardwareHint(
            vendorNumber: nil,
            modelNumber: nil,
            serialNumber: nil
        )
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: unavailable, x: 0)
        ]))
        let originalID = try #require(first.displays.first?.id)

        let moved = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: unavailable, x: 1_920)
        ]))

        #expect(moved.displays.map(\.id) == [originalID])
        #expect(moved.delta.retained.map(\.id) == [originalID])
    }

    @Test
    func uniqueCompleteHardwareHintCanRestoreAnInactiveIdentity() throws {
        var reconciler = DisplayIdentityReconciler()
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101)
        ]))
        let originalID = try #require(first.displays.first?.id)

        _ = reconciler.reconcile(DisplayTopology(displays: []))
        let reconnected = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 99, serialNumber: 101)
        ]))

        #expect(reconnected.displays.map(\.id) == [originalID])
        #expect(reconnected.delta.added.map(\.id) == [originalID])
    }

    @Test(arguments: [
        DisplayHardwareHint(vendorNumber: nil, modelNumber: 9_001, serialNumber: 101),
        DisplayHardwareHint(vendorNumber: 1_552, modelNumber: nil, serialNumber: 101),
        DisplayHardwareHint(vendorNumber: 1_552, modelNumber: 9_001, serialNumber: nil),
        DisplayHardwareHint(vendorNumber: 0, modelNumber: 9_001, serialNumber: 101),
        DisplayHardwareHint(vendorNumber: 1_552, modelNumber: 0, serialNumber: 101),
        DisplayHardwareHint(vendorNumber: 1_552, modelNumber: 9_001, serialNumber: 0)
    ])
    func incompleteOrZeroHardwareHintNeverReconnects(hint: DisplayHardwareHint) throws {
        var reconciler = DisplayIdentityReconciler()
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: hint)
        ]))
        let originalID = try #require(first.displays.first?.id)

        _ = reconciler.reconcile(DisplayTopology(displays: []))
        let reconnected = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: hint)
        ]))

        #expect(reconnected.displays.count == 1)
        #expect(reconnected.displays.first?.id != originalID)
    }

    @Test
    func duplicateHardwareHintsDoNotClaimThePriorIdentity() throws {
        var reconciler = DisplayIdentityReconciler()
        let hint = DisplayHardwareHint(
            vendorNumber: 1_552,
            modelNumber: 9_001,
            serialNumber: 101
        )
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: hint)
        ]))
        let originalID = try #require(first.displays.first?.id)
        _ = reconciler.reconcile(DisplayTopology(displays: []))

        let ambiguous = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 42, hardwareHint: hint, x: -1_920),
            descriptor(runtimeID: 99, hardwareHint: hint, x: 1_920)
        ]))

        #expect(ambiguous.displays.count == 2)
        #expect(Set(ambiguous.displays.map(\.id)).count == 2)
        #expect(!ambiguous.displays.map(\.id).contains(originalID))
    }

    @Test
    func anAmbiguousHistoryCandidateNeverBecomesUniqueByDisconnection() throws {
        var reconciler = DisplayIdentityReconciler()
        let hint = DisplayHardwareHint(
            vendorNumber: 1_552,
            modelNumber: 9_001,
            serialNumber: 101
        )
        let duplicates = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, hardwareHint: hint, x: -1_920),
            descriptor(runtimeID: 42, hardwareHint: hint, x: 1_920)
        ]))
        let duplicateIDs = Set(duplicates.displays.map(\.id))
        #expect(duplicateIDs.count == 2)
        _ = reconciler.reconcile(DisplayTopology(displays: []))

        let later = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 99, hardwareHint: hint)
        ]))
        let laterID = try #require(later.displays.first?.id)

        #expect(!duplicateIDs.contains(laterID))
    }

    @Test
    func duplicateRuntimeIDsAreHandledAsSeparateDescriptorInstances() {
        var reconciler = DisplayIdentityReconciler()
        let result = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101, x: -1_920),
            descriptor(runtimeID: 7, serialNumber: 202, x: 1_920)
        ]))

        #expect(result.displays.count == 2)
        #expect(Set(result.displays.map(\.id)).count == 2)
        #expect(result.delta.added.count == 2)
    }

    @Test
    func unchangedDuplicateRuntimeAndHardwareDescriptorsRetainTheirIdentities() {
        var reconciler = DisplayIdentityReconciler()
        let hint = DisplayHardwareHint(
            vendorNumber: 1_552,
            modelNumber: 9_001,
            serialNumber: 101
        )
        let left = descriptor(runtimeID: 7, hardwareHint: hint, x: -1_920)
        let right = descriptor(runtimeID: 7, hardwareHint: hint, x: 1_920)

        let first = reconciler.reconcile(DisplayTopology(displays: [right, left]))
        let second = reconciler.reconcile(DisplayTopology(displays: [left, right]))

        #expect(!second.topologyChanged)
        #expect(second.delta.added.isEmpty)
        #expect(second.delta.removed.isEmpty)
        #expect(second.delta.retained.map(\.id) == first.displays.map(\.id))
    }

    @Test
    func topologyDeltaReportsAddedRemovedAndRetainedIdentities() throws {
        var reconciler = DisplayIdentityReconciler()
        let initial = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101, x: 0),
            descriptor(runtimeID: 42, serialNumber: 202, x: 1_920)
        ]))
        let removedID = try #require(initial.displays.first { $0.descriptor.runtimeID == 7 }?.id)
        let retainedID = try #require(initial.displays.first { $0.descriptor.runtimeID == 42 }?.id)

        let changed = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 42, serialNumber: 202, x: 0),
            descriptor(runtimeID: 99, serialNumber: 303, x: 1_920)
        ]))

        #expect(changed.topologyChanged)
        #expect(changed.delta.previousRevision == initial.topology.revision)
        #expect(changed.delta.currentRevision == changed.topology.revision)
        #expect(changed.delta.removed.map(\.id) == [removedID])
        #expect(changed.delta.retained.map(\.id) == [retainedID])
        #expect(changed.delta.retained.first?.previous.descriptor.runtimeID == 42)
        #expect(changed.delta.retained.first?.current.descriptor.runtimeID == 42)
        #expect(changed.delta.added.count == 1)
        #expect(changed.delta.added.first?.descriptor.runtimeID == 99)
    }

    @Test
    func fullTopologyEqualityRatherThanRevisionAloneDeterminesChange() {
        var reconciler = DisplayIdentityReconciler()
        let positiveZero = DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101, x: 0.0)
        ])
        let negativeZero = DisplayTopology(displays: [
            descriptor(runtimeID: 7, serialNumber: 101, x: -0.0)
        ])

        _ = reconciler.reconcile(positiveZero)
        let same = reconciler.reconcile(negativeZero)

        #expect(positiveZero == negativeZero)
        #expect(!same.topologyChanged)
    }

    @Test
    func inactiveReconnectHistoryIsBounded() throws {
        var reconciler = DisplayIdentityReconciler()
        let first = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 1, serialNumber: 1_001)
        ]))
        let oldestID = try #require(first.displays.first?.id)

        for number in UInt32(2)...UInt32(65) {
            _ = reconciler.reconcile(DisplayTopology(displays: [
                descriptor(runtimeID: number, serialNumber: 1_000 + number)
            ]))
        }
        _ = reconciler.reconcile(DisplayTopology(displays: []))

        let oldestHardwareReturns = reconciler.reconcile(DisplayTopology(displays: [
            descriptor(runtimeID: 999, serialNumber: 1_001)
        ]))

        #expect(oldestHardwareReturns.displays.first?.id != oldestID)
    }

    private func descriptor(
        runtimeID: UInt32,
        vendorNumber: UInt32 = 1_552,
        modelNumber: UInt32 = 9_001,
        serialNumber: UInt32,
        x: Double = 0
    ) -> DisplayDescriptor {
        descriptor(
            runtimeID: runtimeID,
            hardwareHint: DisplayHardwareHint(
                vendorNumber: vendorNumber,
                modelNumber: modelNumber,
                serialNumber: serialNumber
            ),
            x: x
        )
    }

    private func descriptor(
        runtimeID: UInt32,
        hardwareHint: DisplayHardwareHint,
        x: Double = 0
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            runtimeID: runtimeID,
            hardwareHint: hardwareHint,
            bounds: DisplayBounds(x: x, y: 0, width: 1_920, height: 1_080),
            pixelSize: DisplayPixelSize(width: 3_840, height: 2_160),
            rotationDegrees: 0,
            isMain: x == 0,
            isBuiltIn: runtimeID == 7,
            mirrorSourceRuntimeID: nil
        )
    }
}
