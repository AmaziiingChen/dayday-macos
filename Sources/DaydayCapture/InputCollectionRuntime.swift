@preconcurrency import ApplicationServices
import DaydayCore
import Foundation

/// Presentation-safe health for the aggregate-only input collector.
public enum InputCollectionRuntimeStatus: Equatable, Sendable {
    case idle
    case running
    case waitingForConsent
    case waitingForInputMonitoring
    case pausedForPrivacy
    case unavailable
}

public struct InputCollectionRuntimeSnapshot: Equatable, Sendable {
    public let status: InputCollectionRuntimeStatus
    public let keyboardEnabled: Bool
    public let pointerEnabled: Bool
    public let lastCheckpointAt: Date?

    public init(
        status: InputCollectionRuntimeStatus,
        keyboardEnabled: Bool,
        pointerEnabled: Bool,
        lastCheckpointAt: Date?
    ) {
        self.status = status
        self.keyboardEnabled = keyboardEnabled
        self.pointerEnabled = pointerEnabled
        self.lastCheckpointAt = lastCheckpointAt
    }
}

/// Production coordinator for privacy-closed keyboard and pointer aggregates.
///
/// Capture owns raw platform callbacks and immediately coarsens them. The App
/// gives this runtime only durable consent/control ports and lifecycle facts;
/// it never receives a key event, pointer point, application identity, or
/// window content.
@MainActor
public final class InputCollectionRuntime {
    private let checkpoints: any InputAggregateCheckpointRepository
    private let consents: any CollectionConsentRepository
    private let accumulator: InputAggregationAccumulator
    private let regions = InputDisplayRegionRuntime()
    private let clock: @Sendable () -> Date
    private let timeZoneIdentifier: @Sendable () -> String
    private let excludedBundleIdentifiers: Set<String>
    private let submissionAnchorDidOccur: @Sendable () async -> Void
    private var collector: CGEventTapInputCollector?
    private var checkpointTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<InputCollectionRuntimeSnapshot>.Continuation] = [:]
    private var keyboardConsent = false
    private var pointerConsent = false
    private var globalPaused = false
    private var sessionAvailable = false
    private var lastCheckpointAt: Date?
    private var checkpointedRevisions: [InputAggregatePeriod: UInt64] = [:]
    private var started = false

    public private(set) var snapshot = InputCollectionRuntimeSnapshot(
        status: .idle, keyboardEnabled: false, pointerEnabled: false, lastCheckpointAt: nil
    )

    public init(
        checkpoints: any InputAggregateCheckpointRepository,
        consents: any CollectionConsentRepository,
        clock: @escaping @Sendable () -> Date = Date.init,
        timeZoneIdentifier: @escaping @Sendable () -> String = {
          TimeZone.autoupdatingCurrent.identifier
        },
        excludedBundleIdentifiers: Set<String> = [],
        submissionAnchorDidOccur: @escaping @Sendable () async -> Void = {}
    ) throws {
        self.checkpoints = checkpoints
        self.consents = consents
        self.clock = clock
        self.timeZoneIdentifier = timeZoneIdentifier
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.submissionAnchorDidOccur = submissionAnchorDidOccur
        accumulator = InputAggregationAccumulator(configuration: try .init(
            timeZoneIdentifier: timeZoneIdentifier(),
            collectorVersion: "h1-input-v3",
            defaultLayoutVersion: "physical-v1"
        ))
    }

    public func statusUpdates() -> AsyncStream<InputCollectionRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    /// Returns a point-in-time, aggregate-only view of open hourly buckets for
    /// an on-screen live presentation. This never writes a checkpoint and
    /// never exposes a raw key event, pointer location, timestamp, or order.
    /// Content-free aggregate invalidations are coalesced by Capture before
    /// callers refresh this view, so no raw event crosses the boundary.
    public func liveAggregates() async throws -> [InputAggregate] {
        guard started else { return [] }
        return try await accumulator.openCheckpoints(at: clock()).map(\.aggregate)
    }

    /// Loads durable controls and restores safe open-hour checkpoints. This is
    /// non-prompting; macOS Input Monitoring can only be requested by the UI.
    public func start(sessionAvailable: Bool) async {
        guard !started else { return }
        self.sessionAvailable = sessionAvailable
        do {
            let restored = try await checkpoints.openCheckpoints()
            let now = clock()
            for checkpoint in restored {
                if checkpoint.aggregate.period.end <= now {
                    try await checkpoints.finalize(checkpoint.aggregate)
                } else {
                    try await accumulator.restore(checkpoint)
                    checkpointedRevisions[checkpoint.aggregate.period] = checkpoint.revision
                }
            }
            let backend = MacOSCGEventTapBackend()
            collector = CGEventTapInputCollector(
                accumulator: accumulator,
                backend: backend,
                displayRegions: regions,
                initialGate: closedGate(),
                aggregateDidChange: { [weak self] in
                    await self?.publishInputAggregateChange()
                },
                submissionAnchorDidOccur: submissionAnchorDidOccur
            )
            started = true
            checkpointTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    await self?.checkpointAndFinalize()
                }
            }
            await refreshGates()
        } catch {
            publish(status: .unavailable)
        }
    }

    public func refreshGates() async {
        guard started else { return }
        do {
            async let keyboard = consents.consent(for: .keyboardAggregates)
            async let pointer = consents.consent(for: .pointerAggregates)
            async let global = consents.globalControl()
            let values = try await (keyboard, pointer, global)
            keyboardConsent = values.0.permitsCollection
            pointerConsent = values.1.permitsCollection
            globalPaused = values.2.isPaused
            await reconcile()
        } catch {
            publish(status: .unavailable)
        }
    }

    /// A negative control is held before the App writes its stop intent, so
    /// later raw callbacks cannot slip across the durable stop boundary.
    public func holdForNegativeControl() async {
        guard started else { return }
        keyboardConsent = false
        pointerConsent = false
        await collector?.updateGate(closedGate())
        await checkpointAndFinalize()
    }

    public func setSessionAvailable(_ available: Bool) async {
        sessionAvailable = available
        await reconcile()
        if !available { await checkpointAndFinalize() }
    }

    public func shutdown() async {
        checkpointTask?.cancel()
        checkpointTask = nil
        await collector?.stop()
        await checkpointAndFinalize()
        collector = nil
        started = false
        publish(status: .idle)
        let continuations = subscribers.values
        subscribers.removeAll()
        continuations.forEach { $0.finish() }
    }

    private func reconcile() async {
        guard let collector else { return }
        let gate = makeGate()
        await collector.updateGate(gate)
        let status: InputCollectionRuntimeStatus
        if !keyboardConsent && !pointerConsent { status = .waitingForConsent }
        else if globalPaused || !sessionAvailable { status = .pausedForPrivacy }
        else if !CGPreflightListenEventAccess() { status = .waitingForInputMonitoring }
        else { status = .running }
        publish(status: status)
    }

    private func checkpointAndFinalize() async {
        guard started else { return }
        let now = clock()
        do {
            let finalized = try await accumulator.completedAggregates(endingBefore: now)
            for aggregate in finalized { try await checkpoints.finalize(aggregate) }
            try await accumulator.seal(finalized)
            let openCheckpoints = try await accumulator.openCheckpoints(at: now)
            let openPeriods = Set(openCheckpoints.map(\.aggregate.period))
            checkpointedRevisions = checkpointedRevisions.filter { openPeriods.contains($0.key) }
            for checkpoint in openCheckpoints
            where checkpointedRevisions[checkpoint.aggregate.period] != checkpoint.revision {
                try await checkpoints.upsert(checkpoint)
                checkpointedRevisions[checkpoint.aggregate.period] = checkpoint.revision
            }
            lastCheckpointAt = now
            publish(status: snapshot.status)
        } catch {
            await collector?.stop()
            publish(status: .unavailable)
        }
    }

    private func makeGate() -> InputCollectionGate {
        let authorization: AuthorizationState = CGPreflightListenEventAccess() ? .authorized : .unknown
        return InputCollectionGate(
            keyboard: .init(isEnabled: keyboardConsent && !globalPaused, authorization: authorization),
            pointer: .init(isEnabled: pointerConsent && !globalPaused, authorization: authorization),
            isUserSessionAvailable: sessionAvailable,
            foregroundSafety: .unknown
        )
    }

    private func closedGate() -> InputCollectionGate {
        InputCollectionGate(
            keyboard: .init(isEnabled: false, authorization: .unknown),
            pointer: .init(isEnabled: false, authorization: .unknown),
            isUserSessionAvailable: false,
            foregroundSafety: .unknown
        )
    }

    private func publish(status: InputCollectionRuntimeStatus) {
        let next = InputCollectionRuntimeSnapshot(
            status: status,
            keyboardEnabled: keyboardConsent,
            pointerEnabled: pointerConsent,
            lastCheckpointAt: lastCheckpointAt
        )
        guard next != snapshot else { return }
        snapshot = next
        subscribers.values.forEach { $0.yield(snapshot) }
    }

    /// Aggregate changes may leave the health snapshot unchanged. Yield the
    /// existing value as a content-free invalidation instead of suppressing it
    /// through the status de-duplication guard above.
    private func publishInputAggregateChange() {
        subscribers.values.forEach { $0.yield(snapshot) }
    }

}

/// Keeps an immutable, event-driven display snapshot for pointer normalization.
/// Display enumeration never happens on a pointer event, and display bounds
/// remain confined to Capture instead of crossing into presentation.
private final class InputDisplayRegionRuntime: InputDisplayRegionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var reconciler = DisplayIdentityReconciler()
    private var regions: [InputDisplayRegion] = []
    private var displayCallbackRegistered = false

    init() {
        refresh()
        displayCallbackRegistered = CGDisplayRegisterReconfigurationCallback(
            Self.displayDidReconfigure,
            Unmanaged.passUnretained(self).toOpaque()
        ) == .success
    }

    deinit {
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayDidReconfigure,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    func currentRegions() -> [InputDisplayRegion] {
        lock.withLock { regions }
    }

    private func refresh() {
        do {
            let topology = try DisplayTopology(displays: CoreGraphicsDisplayInventory().onlineDisplays())
            lock.withLock {
                let result = reconciler.reconcile(topology)
                regions = result.displays.map {
                    InputDisplayRegion(
                        display: DisplayContext(
                            id: $0.id,
                            topologyRevision: result.topology.revision.rawValue
                        ),
                        bounds: $0.descriptor.bounds
                    )
                }
            }
        } catch {
            lock.withLock { regions = [] }
        }
    }

    private static let displayDidReconfigure: CGDisplayReconfigurationCallBack = {
        _, _, userInfo in
        guard let userInfo else { return }
        let runtime = Unmanaged<InputDisplayRegionRuntime>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.global(qos: .utility).async {
            runtime.refresh()
        }
    }
}
