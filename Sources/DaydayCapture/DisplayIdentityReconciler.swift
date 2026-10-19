import DaydayCore
import Foundation

/// A display descriptor paired with an opaque Core identity.
///
/// The identity is valid only for the lifetime of the reconciler that assigned it. It is not a
/// hardware identifier and does not claim stability across processes, reboots, or machines.
public struct ReconciledDisplay: Sendable, Equatable {
    public let id: DisplayID
    public let descriptor: DisplayDescriptor

    public init(id: DisplayID, descriptor: DisplayDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }
}

/// The before-and-after descriptors for an identity present in two adjacent snapshots.
public struct RetainedDisplayIdentity: Sendable, Equatable {
    public var id: DisplayID { previous.id }
    public let previous: ReconciledDisplay
    public let current: ReconciledDisplay

    init(previous: ReconciledDisplay, current: ReconciledDisplay) {
        precondition(previous.id == current.id)
        self.previous = previous
        self.current = current
    }
}

/// An identity-aware topology delta between two adjacent inventory snapshots.
public struct DisplayIdentityDelta: Sendable, Equatable {
    public let previousRevision: DisplayTopologyRevision?
    public let currentRevision: DisplayTopologyRevision
    public let added: [ReconciledDisplay]
    public let removed: [ReconciledDisplay]
    public let retained: [RetainedDisplayIdentity]

    init(
        previousRevision: DisplayTopologyRevision?,
        currentRevision: DisplayTopologyRevision,
        added: [ReconciledDisplay],
        removed: [ReconciledDisplay],
        retained: [RetainedDisplayIdentity]
    ) {
        self.previousRevision = previousRevision
        self.currentRevision = currentRevision
        self.added = added
        self.removed = removed
        self.retained = retained
    }
}

/// The complete result of reconciling one metadata-only display inventory.
public struct DisplayIdentityReconciliation: Sendable, Equatable {
    public let topology: DisplayTopology
    public let displays: [ReconciledDisplay]
    public let delta: DisplayIdentityDelta

    /// Uses full ``DisplayTopology`` equality. Revisions are only cheap change tokens and are not
    /// assumed to be collision-free identities.
    public let topologyChanged: Bool

    init(
        topology: DisplayTopology,
        displays: [ReconciledDisplay],
        delta: DisplayIdentityDelta,
        topologyChanged: Bool
    ) {
        self.topology = topology
        self.displays = displays
        self.delta = delta
        self.topologyChanged = topologyChanged
    }
}

/// Reconciles platform display descriptors with opaque domain identifiers in volatile memory.
///
/// A unique, nonzero runtime ID wins while a display remains in adjacent active snapshots. After
/// a disconnection, a complete and nonzero vendor/model/serial tuple may restore an identity only
/// when both the current descriptor and remembered candidate are unambiguous. Every uncertain
/// case receives a fresh identity rather than making a false continuity claim.
///
/// The reconciler does not persist anything, enumerate displays, request authorization, or capture
/// pixels. Create a new instance for each application process.
public struct DisplayIdentityReconciler: Sendable {
    private static let maximumInactiveHardwareCandidates = 64

    private var previousTopology: DisplayTopology?
    private var activeDisplays: [ReconciledDisplay] = []
    private var inactiveCandidates: [StrongHardwareHint: ReconnectCandidate] = [:]
    private var inactiveCandidateOrder: [StrongHardwareHint] = []

    public init() {}

    public mutating func reconcile(
        _ topology: DisplayTopology
    ) -> DisplayIdentityReconciliation {
        let previousTopology = self.previousTopology
        let previousDisplays = activeDisplays
        let descriptors = topology.displays

        let currentRuntimeCounts = counts(of: descriptors.map(\.runtimeID))
        let previousRuntimeCounts = counts(of: previousDisplays.map(\.descriptor.runtimeID))
        let currentHardwareCounts = counts(
            of: descriptors.compactMap { StrongHardwareHint($0.hardwareHint) }
        )

        var resolvedIDs = [DisplayID?](repeating: nil, count: descriptors.count)
        var usedIDs = Set<DisplayID>()

        // Preserve identities for an exactly unchanged descriptor multiset before applying any
        // heuristic. This keeps duplicate runtime/hardware values stable across identical
        // snapshots; normalized topology order gives identical occurrences deterministic pairing.
        for (currentIndex, descriptor) in descriptors.enumerated() {
            guard let previous = previousDisplays.first(where: {
                $0.descriptor == descriptor && !usedIDs.contains($0.id)
            }) else {
                continue
            }
            resolvedIDs[currentIndex] = previous.id
            usedIDs.insert(previous.id)
        }

        // Runtime IDs are useful only when nonzero and unique in both adjacent snapshots. Matching
        // by indexed descriptors avoids dictionary overwrite if CoreGraphics ever reports a
        // duplicate runtime ID. If both snapshots contain complete hardware facts that conflict,
        // the runtime ID may have been recycled and must not carry identity across displays.
        for (currentIndex, descriptor) in descriptors.enumerated()
        where resolvedIDs[currentIndex] == nil {
            let runtimeID = descriptor.runtimeID
            guard runtimeID != 0,
                  currentRuntimeCounts[runtimeID] == 1,
                  previousRuntimeCounts[runtimeID] == 1,
                  let previous = previousDisplays.first(where: {
                      $0.descriptor.runtimeID == runtimeID && !usedIDs.contains($0.id)
                  }) else {
                continue
            }
            if let currentHint = StrongHardwareHint(descriptor.hardwareHint),
               let previousHint = StrongHardwareHint(previous.descriptor.hardwareHint),
               currentHint != previousHint {
                continue
            }

            resolvedIDs[currentIndex] = previous.id
            usedIDs.insert(previous.id)
        }

        // Hardware hints are only a conservative reconnect fallback. Missing values, zeros,
        // duplicate current hints, duplicate historical candidates, and already-claimed IDs all
        // fail closed into a fresh identity below.
        for (currentIndex, descriptor) in descriptors.enumerated()
        where resolvedIDs[currentIndex] == nil {
            guard let hint = StrongHardwareHint(descriptor.hardwareHint),
                  currentHardwareCounts[hint] == 1 else {
                continue
            }

            var candidateIDs = Set<DisplayID>()
            var isAmbiguous = false

            for previous in previousDisplays where !usedIDs.contains(previous.id) {
                if StrongHardwareHint(previous.descriptor.hardwareHint) == hint {
                    candidateIDs.insert(previous.id)
                }
            }

            switch inactiveCandidates[hint] {
            case let .unique(id):
                if !usedIDs.contains(id) {
                    candidateIDs.insert(id)
                }
            case .ambiguous:
                isAmbiguous = true
            case nil:
                break
            }

            guard !isAmbiguous, candidateIDs.count == 1,
                  let candidate = candidateIDs.first else {
                continue
            }

            resolvedIDs[currentIndex] = candidate
            usedIDs.insert(candidate)
        }

        for index in descriptors.indices where resolvedIDs[index] == nil {
            let id = freshID(excluding: usedIDs)
            resolvedIDs[index] = id
            usedIDs.insert(id)
        }

        let currentDisplays = descriptors.indices.map { index in
            guard let id = resolvedIDs[index] else {
                preconditionFailure("Every display descriptor must receive an identity")
            }
            return ReconciledDisplay(id: id, descriptor: descriptors[index])
        }

        updateInactiveCandidates(
            previousDisplays: previousDisplays,
            currentIDs: usedIDs
        )

        let previousByID = Dictionary(uniqueKeysWithValues: previousDisplays.map { ($0.id, $0) })
        let currentIDsForDelta = Set(currentDisplays.map(\.id))
        let previousIDsForDelta = Set(previousDisplays.map(\.id))

        let added = currentDisplays.filter { !previousIDsForDelta.contains($0.id) }
        let removed = previousDisplays.filter { !currentIDsForDelta.contains($0.id) }
        let retained = currentDisplays.compactMap { current -> RetainedDisplayIdentity? in
            guard let previous = previousByID[current.id] else { return nil }
            return RetainedDisplayIdentity(previous: previous, current: current)
        }
        let delta = DisplayIdentityDelta(
            previousRevision: previousTopology?.revision,
            currentRevision: topology.revision,
            added: added,
            removed: removed,
            retained: retained
        )

        self.previousTopology = topology
        activeDisplays = currentDisplays

        return DisplayIdentityReconciliation(
            topology: topology,
            displays: currentDisplays,
            delta: delta,
            topologyChanged: previousTopology.map { $0 != topology } ?? true
        )
    }

    private mutating func updateInactiveCandidates(
        previousDisplays: [ReconciledDisplay],
        currentIDs: Set<DisplayID>
    ) {
        let claimedKeys = inactiveCandidates.compactMap { hint, candidate -> StrongHardwareHint? in
            guard case let .unique(id) = candidate, currentIDs.contains(id) else { return nil }
            return hint
        }
        for hint in claimedKeys {
            removeInactiveCandidate(for: hint)
        }

        for previous in previousDisplays where !currentIDs.contains(previous.id) {
            guard let hint = StrongHardwareHint(previous.descriptor.hardwareHint) else { continue }
            rememberInactive(previous.id, for: hint)
        }
    }

    private mutating func rememberInactive(_ id: DisplayID, for hint: StrongHardwareHint) {
        if let existing = inactiveCandidates[hint] {
            switch existing {
            case let .unique(existingID) where existingID == id:
                return
            case .unique, .ambiguous:
                inactiveCandidates[hint] = .ambiguous
                return
            }
        }

        inactiveCandidates[hint] = .unique(id)
        inactiveCandidateOrder.append(hint)

        while inactiveCandidateOrder.count > Self.maximumInactiveHardwareCandidates {
            let expired = inactiveCandidateOrder.removeFirst()
            inactiveCandidates.removeValue(forKey: expired)
        }
    }

    private mutating func removeInactiveCandidate(for hint: StrongHardwareHint) {
        inactiveCandidates.removeValue(forKey: hint)
        if let index = inactiveCandidateOrder.firstIndex(of: hint) {
            inactiveCandidateOrder.remove(at: index)
        }
    }

    private func freshID(excluding usedIDs: Set<DisplayID>) -> DisplayID {
        var id = DisplayID()
        let reservedIDs = Set(activeDisplays.map(\.id)).union(
            inactiveCandidates.compactMap { _, candidate in
                guard case let .unique(id) = candidate else { return nil }
                return id
            }
        )
        while usedIDs.contains(id) || reservedIDs.contains(id) {
            id = DisplayID()
        }
        return id
    }
}

private struct StrongHardwareHint: Sendable, Hashable {
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

    init?(_ hint: DisplayHardwareHint) {
        guard let vendorNumber = hint.vendorNumber, vendorNumber != 0,
              let modelNumber = hint.modelNumber, modelNumber != 0,
              let serialNumber = hint.serialNumber, serialNumber != 0 else {
            return nil
        }

        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }
}

private enum ReconnectCandidate: Sendable {
    case unique(DisplayID)
    case ambiguous
}

private func counts<Value: Hashable>(of values: [Value]) -> [Value: Int] {
    values.reduce(into: [:]) { counts, value in
        counts[value, default: 0] += 1
    }
}
