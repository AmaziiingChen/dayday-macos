import CoreGraphics
import DaydayCore
import Foundation

/// Product and platform facts that decide whether physical input collection may run.
///
/// This type is intentionally module-internal. Application composition updates it
/// from the two independent collector consents, lifecycle boundaries, and the
/// foreground privacy gate. Foreground safety never blocks content-free physical
/// counts; it only admits the external committed-text sampler. No event-shaped
/// value crosses the module boundary.
struct InputCollectionGate: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        var isEnabled: Bool
        var authorization: AuthorizationState
        var pauseReasons: Set<CollectionPauseReason>

        init(
            isEnabled: Bool,
            authorization: AuthorizationState,
            pauseReasons: Set<CollectionPauseReason> = []
        ) {
            self.isEnabled = isEnabled
            self.authorization = authorization
            self.pauseReasons = pauseReasons
        }

        var permitsCollection: Bool {
            isEnabled && authorization.permitsCollection && pauseReasons.isEmpty
        }
    }

    enum ForegroundSafety: Equatable, Sendable {
        case allowed
        case excluded
        case unknown
    }

    var keyboard: Channel
    var pointer: Channel
    var isUserSessionAvailable: Bool
    var foregroundSafety: ForegroundSafety

    var permitsTap: Bool {
        isUserSessionAvailable
            && (keyboard.permitsCollection || pointer.permitsCollection)
    }
}

enum InputEventTapRuntime: Equatable, Sendable {
    enum UnavailableReason: Equatable, Sendable {
        case productGateClosed
        case inputMonitoringAuthorizationRequired
        case secureInput
        case backendUnavailable
        case aggregateInvariantViolated
    }

    case stopped
    case starting
    case running
    case waitingToRecover(attempt: Int, reason: UnavailableReason)
    case unavailable(UnavailableReason)
}

/// Sanitized diagnostics only. Counts, timestamps, locations, and key identities
/// are deliberately absent.
struct InputEventTapCollectorSnapshot: Equatable, Sendable {
    let runtime: InputEventTapRuntime
    let isKeyboardCollectionEnabled: Bool
    let isPointerCollectionEnabled: Bool
}

/// The smallest raw platform shape needed before immediate coarsening. It is
/// module-internal, non-Codable, never logged, and never returned from Capture.
enum TransientInputEvent: Sendable {
    struct Point: Sendable {
        let x: Double
        let y: Double
    }

    case keyDown(
        observedAt: Date,
        hardwareKeyCode: UInt16,
        isAutoRepeat: Bool
    )
    case pointerMoved(observedAt: Date, point: Point)
    case pointerButtonDown(
        observedAt: Date,
        point: Point,
        button: TransientPointerButton
    )
    case scroll(observedAt: Date, point: Point, deltaX: Int64, deltaY: Int64)
    case secureInputBegan
    case authorizationLost
    case tapDisabled
    case mailboxOverflow
}

protocol InputEventTapBackend: Sendable {
    func start(
        sessionID: UInt64,
        handler: @escaping @Sendable ([TransientInputEvent]) async -> Void
    ) async throws

    func stop(sessionID: UInt64) async
}

struct InputDisplayRegion: Sendable {
    let display: DisplayContext
    let minimumX: Double
    let minimumY: Double
    let width: Double
    let height: Double

    init(display: DisplayContext, bounds: DisplayBounds) {
        self.display = display
        self.minimumX = bounds.x
        self.minimumY = bounds.y
        self.width = bounds.width
        self.height = bounds.height
    }

    func normalizedLocation(
        for point: TransientInputEvent.Point
    ) -> TransientNormalizedPointerLocation? {
        guard minimumX.isFinite, minimumY.isFinite,
              width.isFinite, height.isFinite,
              width > 0, height > 0,
              point.x.isFinite, point.y.isFinite,
              point.x >= minimumX, point.x < minimumX + width,
              point.y >= minimumY, point.y < minimumY + height else {
            return nil
        }
        return try? TransientNormalizedPointerLocation(
            x: (point.x - minimumX) / width,
            y: (point.y - minimumY) / height
        )
    }
}

protocol InputDisplayRegionProviding: Sendable {
    func currentRegions() -> [InputDisplayRegion]
}

/// Coordinates the real tap backend with the privacy-closed accumulator.
///
/// Every callback is revalidated against live product state, live TCC state,
/// and secure input before a contribution is constructed. A single previous
/// pointer sample is retained only to derive distance and bounded dwell; there
/// is no event list or replay buffer.
actor CGEventTapInputCollector {
    typealias BooleanProbe = @Sendable () -> Bool

    private struct PreviousPointerSample: Sendable {
        let observedAt: Date
        let point: TransientInputEvent.Point
        let region: InputDisplayRegion
        let location: TransientNormalizedPointerLocation
    }

    private static let maximumDwellMilliseconds: UInt64 = 5_000

    private let accumulator: InputAggregationAccumulator
    private let backend: any InputEventTapBackend
    private let displayRegions: any InputDisplayRegionProviding
    private let inputMonitoringPreflight: BooleanProbe
    private let secureInputPreflight: BooleanProbe
    private let clock: @Sendable () -> Date
    private let recoveryDelaysNanoseconds: [UInt64]
    private let recoveryPreDispatchHook: @Sendable () async -> Void
    /// Content-free invalidation for aggregate presentations. Rapid input is
    /// coalesced before this crosses the Capture boundary.
    private let aggregateDidChange: @Sendable () async -> Void
    /// A content-free signal emitted only for a Return/Enter press after the event has passed the
    /// same authorization and secure-input gates as aggregate collection. It never contains the
    /// key code, timestamp, text, modifier state, or an assertion that a message was sent.
    private let submissionAnchorDidOccur: @Sendable () async -> Void

    private var gate: InputCollectionGate
    private var runtime: InputEventTapRuntime = .stopped
    private var activeSessionID: UInt64?
    private var nextSessionID: UInt64 = 1
    private var previousPointer: PreviousPointerSample?
    private var recoveryAttempt = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryToken: UUID?
    private var aggregateNotificationTask: Task<Void, Never>?
    private var aggregateNotificationRevision: UInt64 = 0

    init(
        accumulator: InputAggregationAccumulator,
        backend: any InputEventTapBackend,
        displayRegions: any InputDisplayRegionProviding,
        initialGate: InputCollectionGate,
        inputMonitoringPreflight: @escaping BooleanProbe = {
            CGPreflightListenEventAccess()
        },
        secureInputPreflight: @escaping BooleanProbe = {
            MacOSCGEventTapBackend.isSecureInputEnabled()
        },
        clock: @escaping @Sendable () -> Date = Date.init,
        recoveryDelaysNanoseconds: [UInt64] = [
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000,
        ],
        recoveryPreDispatchHook: @escaping @Sendable () async -> Void = {},
        aggregateDidChange: @escaping @Sendable () async -> Void = {},
        submissionAnchorDidOccur: @escaping @Sendable () async -> Void = {}
    ) {
        self.accumulator = accumulator
        self.backend = backend
        self.displayRegions = displayRegions
        self.gate = initialGate
        self.inputMonitoringPreflight = inputMonitoringPreflight
        self.secureInputPreflight = secureInputPreflight
        self.clock = clock
        self.recoveryDelaysNanoseconds = recoveryDelaysNanoseconds
        self.recoveryPreDispatchHook = recoveryPreDispatchHook
        self.aggregateDidChange = aggregateDidChange
        self.submissionAnchorDidOccur = submissionAnchorDidOccur
    }

    func snapshot() -> InputEventTapCollectorSnapshot {
        InputEventTapCollectorSnapshot(
            runtime: runtime,
            isKeyboardCollectionEnabled: gate.keyboard.permitsCollection,
            isPointerCollectionEnabled: gate.pointer.permitsCollection
        )
    }

    /// Applies the newest consent/lifecycle/privacy state and synchronously
    /// reconciles the backend before returning.
    func updateGate(_ gate: InputCollectionGate) async {
        if self.gate.pointer.permitsCollection, !gate.pointer.permitsCollection {
            previousPointer = nil
        }
        self.gate = gate
        cancelRecovery(resetAttempt: true)
        guard gate.permitsTap else {
            await haltBackend(then: .unavailable(.productGateClosed))
            return
        }
        await beginIfPermitted()
    }

    func start() async {
        cancelRecovery(resetAttempt: true)
        await beginIfPermitted()
    }

    func stop() async {
        cancelRecovery(resetAttempt: true)
        await haltBackend(then: .stopped)
    }

    private func beginIfPermitted() async {
        guard activeSessionID == nil else {
            runtime = .running
            return
        }
        guard gate.permitsTap else {
            runtime = .unavailable(.productGateClosed)
            return
        }
        guard inputMonitoringPreflight() else {
            runtime = .unavailable(.inputMonitoringAuthorizationRequired)
            return
        }
        guard !secureInputPreflight() || gate.pointer.permitsCollection else {
            scheduleRecovery(reason: .secureInput)
            return
        }

        let sessionID = nextSessionID
        let increment = nextSessionID.addingReportingOverflow(1)
        guard !increment.overflow else {
            runtime = .unavailable(.aggregateInvariantViolated)
            return
        }
        nextSessionID = increment.partialValue
        activeSessionID = sessionID
        runtime = .starting
        let callback: @Sendable ([TransientInputEvent]) async -> Void = { [weak self] events in
            await self?.receive(events, sessionID: sessionID)
        }

        do {
            try await backend.start(sessionID: sessionID, handler: callback)
        } catch {
            if activeSessionID == sessionID {
                activeSessionID = nil
                previousPointer = nil
                scheduleRecovery(reason: .backendUnavailable)
            } else {
                await backend.stop(sessionID: sessionID)
            }
            return
        }

        guard activeSessionID == sessionID else {
            await backend.stop(sessionID: sessionID)
            return
        }
        guard gate.permitsTap else {
            await haltBackend(then: .unavailable(.productGateClosed))
            return
        }
        guard inputMonitoringPreflight() else {
            await haltBackend(then: .unavailable(.inputMonitoringAuthorizationRequired))
            return
        }
        guard !secureInputPreflight() || gate.pointer.permitsCollection else {
            await haltBackend(then: .unavailable(.secureInput))
            scheduleRecovery(reason: .secureInput)
            return
        }

        recoveryAttempt = 0
        runtime = .running
    }

    private func receive(_ events: [TransientInputEvent], sessionID: UInt64) async {
        for event in events {
            await receive(event, sessionID: sessionID)
            guard activeSessionID == sessionID else { return }
        }
    }

    private func receive(_ event: TransientInputEvent, sessionID: UInt64) async {
        guard activeSessionID == sessionID else { return }
        guard gate.permitsTap else {
            await haltBackend(then: .unavailable(.productGateClosed))
            return
        }
        guard inputMonitoringPreflight() else {
            await haltBackend(then: .unavailable(.inputMonitoringAuthorizationRequired))
            return
        }
        do {
            switch event {
            case let .keyDown(
                observedAt,
                hardwareKeyCode,
                isAutoRepeat
            ):
                guard runtime == .running,
                      gate.keyboard.permitsCollection,
                      !isAutoRepeat else { return }
                guard !secureInputPreflight() else {
                    // Secure Input is a keyboard boundary, not a reason to
                    // discard independent pointer aggregation. When pointer
                    // collection remains enabled, keep the tap alive and
                    // simply suppress this key contribution.
                    if !gate.pointer.permitsCollection {
                        await haltBackend(then: .unavailable(.secureInput))
                        scheduleRecovery(reason: .secureInput)
                    }
                    return
                }
                try await accumulator.record(
                    TransientPhysicalKeySample(
                        occurredAt: observedAt,
                        hardwareKeyCode: hardwareKeyCode,
                        applicationIdentifier: nil,
                        layoutVersion: "physical-v1"
                    ),
                    disposition: .allowed
                )
                scheduleAggregateChangeNotification()
                if Self.isSubmissionKey(hardwareKeyCode) {
                    Task { [submissionAnchorDidOccur] in
                      await submissionAnchorDidOccur()
                    }
                }

            case let .pointerMoved(observedAt, point):
                guard runtime == .running, gate.pointer.permitsCollection else { return }
                try await recordPointerMovement(observedAt: observedAt, point: point)
                scheduleAggregateChangeNotification()

            case let .pointerButtonDown(observedAt, point, button):
                guard runtime == .running,
                      gate.pointer.permitsCollection,
                      let resolved = await resolve(point) else { return }
                try await accumulator.record(
                    TransientPointerSample(
                        occurredAt: observedAt,
                        display: resolved.region.display,
                        applicationIdentifier: nil,
                        location: resolved.location,
                        action: .click(button)
                    ),
                    disposition: .allowed
                )
                scheduleAggregateChangeNotification()

            case let .scroll(observedAt, point, deltaX, deltaY):
                guard runtime == .running,
                      gate.pointer.permitsCollection,
                      let resolved = await resolve(point) else { return }
                try await recordScroll(
                    observedAt: observedAt,
                    resolved: resolved,
                    deltaX: deltaX,
                    deltaY: deltaY
                )
                scheduleAggregateChangeNotification()

            case .secureInputBegan:
                if !gate.pointer.permitsCollection {
                    await haltBackend(then: .unavailable(.secureInput))
                    scheduleRecovery(reason: .secureInput)
                }

            case .authorizationLost:
                await haltBackend(then: .unavailable(.inputMonitoringAuthorizationRequired))

            case .tapDisabled, .mailboxOverflow:
                await haltBackend(then: .unavailable(.backendUnavailable))
                scheduleRecovery(reason: .backendUnavailable)
            }
        } catch {
            await haltBackend(then: .unavailable(.aggregateInvariantViolated))
        }
    }

    private func recordPointerMovement(
        observedAt: Date,
        point: TransientInputEvent.Point
    ) async throws {
        guard let current = await resolve(point) else {
            previousPointer = nil
            return
        }

        if let previous = previousPointer,
           previous.region.display == current.region.display,
           observedAt >= previous.observedAt {
            let elapsed = observedAt.timeIntervalSince(previous.observedAt)
            if elapsed.isFinite, elapsed > 0 {
                let boundedElapsed = min(
                    elapsed,
                    Double(Self.maximumDwellMilliseconds) / 1_000
                )
                let dwell = UInt64((boundedElapsed * 1_000).rounded(.towardZero))
                if dwell > 0 {
                    try await accumulator.record(
                        TransientPointerSample(
                            occurredAt: previous.observedAt,
                            display: previous.region.display,
                            applicationIdentifier: nil,
                            location: previous.location,
                            action: .dwell(milliseconds: dwell)
                        ),
                        disposition: .allowed
                    )
                }
            }

            let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
            let scaledDistance = distance * 1_000
            if scaledDistance.isFinite, scaledDistance > 0,
               scaledDistance <= Double(UInt64.max - 4_095) {
                let milliPoints = UInt64(scaledDistance.rounded())
                if milliPoints > 0 {
                    try await accumulator.record(
                        TransientPointerSample(
                            occurredAt: observedAt,
                            display: current.region.display,
                            applicationIdentifier: nil,
                            location: current.location,
                            action: .movement(distanceMilliPoints: milliPoints)
                        ),
                        disposition: .allowed
                    )
                }
            }
        }

        previousPointer = PreviousPointerSample(
            observedAt: observedAt,
            point: point,
            region: current.region,
            location: current.location
        )
    }

    private func recordScroll(
        observedAt: Date,
        resolved: (region: InputDisplayRegion, location: TransientNormalizedPointerLocation),
        deltaX: Int64,
        deltaY: Int64
    ) async throws {
        var hasRecordedAction = false
        for (direction, magnitude) in [
            (deltaY >= 0 ? TransientScrollDirection.up : .down, magnitude(of: deltaY)),
            (deltaX >= 0 ? TransientScrollDirection.left : .right, magnitude(of: deltaX)),
        ] where magnitude > 0 {
            try await accumulator.record(
                TransientPointerSample(
                    occurredAt: observedAt,
                    display: resolved.region.display,
                    applicationIdentifier: nil,
                    location: resolved.location,
                    action: .scroll(
                        direction,
                        magnitude: magnitude,
                        eventCount: hasRecordedAction ? 0 : 1
                    )
                ),
                disposition: .allowed
            )
            hasRecordedAction = true
        }
    }

    private func magnitude(of value: Int64) -> UInt64 {
        value == .min ? UInt64(Int64.max) + 1 : UInt64(Swift.abs(value))
    }

    private static func isSubmissionKey(_ hardwareKeyCode: UInt16) -> Bool {
        // ANSI Return and the keypad Enter key. The raw code is used only inside Capture and is
        // intentionally never forwarded through the callback above.
        hardwareKeyCode == 36 || hardwareKeyCode == 76
    }

    /// A single 80 ms notification window is short enough to feel immediate,
    /// while preventing fast typing or clicking from scheduling one expensive
    /// presentation read per operating-system callback.
    private func scheduleAggregateChangeNotification() {
        aggregateNotificationRevision &+= 1
        startAggregateChangeNotificationIfNeeded()
    }

    private func startAggregateChangeNotificationIfNeeded() {
        guard aggregateNotificationTask == nil else { return }
        aggregateNotificationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.deliverAggregateChangeNotification()
        }
    }

    private func deliverAggregateChangeNotification() async {
        let deliveredRevision = aggregateNotificationRevision
        await aggregateDidChange()
        aggregateNotificationTask = nil
        if deliveredRevision != aggregateNotificationRevision {
            startAggregateChangeNotificationIfNeeded()
        }
    }

    private func resolve(
        _ point: TransientInputEvent.Point
    ) async -> (region: InputDisplayRegion, location: TransientNormalizedPointerLocation)? {
        let matches = displayRegions.currentRegions().compactMap { region in
            region.normalizedLocation(for: point).map { (region, $0) }
        }
        // Mirrored or otherwise overlapping layouts are ambiguous. Recording no
        // heat-map contribution is safer than guessing a display identity.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func haltBackend(then nextRuntime: InputEventTapRuntime) async {
        cancelRecovery(resetAttempt: false)
        let sessionID = activeSessionID
        activeSessionID = nil
        previousPointer = nil
        runtime = nextRuntime
        if let sessionID {
            await backend.stop(sessionID: sessionID)
        }

    }

    private func scheduleRecovery(reason: InputEventTapRuntime.UnavailableReason) {
        guard gate.permitsTap else {
            runtime = .unavailable(.productGateClosed)
            return
        }
        let delay: UInt64
        if recoveryAttempt < recoveryDelaysNanoseconds.count {
            delay = recoveryDelaysNanoseconds[recoveryAttempt]
            recoveryAttempt += 1
        } else if reason == .secureInput,
                  let maximumDelay = recoveryDelaysNanoseconds.last {
            // Secure input commonly lasts longer than one backoff window. Keep
            // checking at the capped interval so ordinary password entry does
            // not permanently disable collection for the rest of the day.
            delay = maximumDelay
        } else {
            runtime = .unavailable(reason)
            return
        }
        let attempt = recoveryAttempt
        runtime = .waitingToRecover(attempt: attempt, reason: reason)
        recoveryTask?.cancel()
        let token = UUID()
        recoveryToken = token
        let recoveryPreDispatchHook = recoveryPreDispatchHook
        recoveryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await recoveryPreDispatchHook()
            await self?.recoveryTimerFired(token: token)
        }
    }

    private func recoveryTimerFired(token: UUID) async {
        guard recoveryToken == token else { return }
        recoveryToken = nil
        recoveryTask = nil
        guard gate.permitsTap else {
            runtime = .unavailable(.productGateClosed)
            return
        }
        guard inputMonitoringPreflight() else {
            runtime = .unavailable(.inputMonitoringAuthorizationRequired)
            return
        }
        if secureInputPreflight(), !gate.pointer.permitsCollection {
            scheduleRecovery(reason: .secureInput)
            return
        }
        await beginIfPermitted()
    }

    private func cancelRecovery(resetAttempt: Bool) {
        recoveryToken = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        if resetAttempt { recoveryAttempt = 0 }
    }

}
