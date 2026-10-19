import CoreGraphics
import DaydayCore
import Foundation
import Testing
@testable import DaydayCapture

struct CGEventTapInputCollectorTests {
    @Test
    func aggregateInvalidationsAreImmediateAndCoalescedForKeyboardAndClicks() async throws {
        let backend = FakeInputEventTapBackend()
        let notifications = LockedCounter()
        let collector = makeCollector(
            accumulator: try makeAccumulator(),
            backend: backend,
            aggregateDidChange: { notifications.increment() }
        )

        await collector.start()
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:01Z"),
            hardwareKeyCode: 12,
            isAutoRepeat: false
        ))
        try await eventually { notifications.value == 1 }

        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:02Z"),
            hardwareKeyCode: 12,
            isAutoRepeat: true
        ))
        try await Task.sleep(for: .milliseconds(70))
        #expect(notifications.value == 1)

        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:00:03Z"),
            point: .init(x: 100, y: 100),
            button: .left
        ))
        try await eventually { notifications.value == 2 }
    }

    @Test
    func turnsModifierFlagTransitionsIntoPressesWithoutCountingReleases() {
        var reducer = ModifierKeyPressReducer()

        #expect(reducer.pressedHardwareKeyCode(for: 56, flags: [.maskShift]) == 56)
        #expect(reducer.pressedHardwareKeyCode(for: 60, flags: [.maskShift]) == 60)
        #expect(reducer.pressedHardwareKeyCode(for: 60, flags: [.maskShift]) == nil)
        #expect(reducer.pressedHardwareKeyCode(for: 56, flags: []) == nil)
        #expect(reducer.pressedHardwareKeyCode(for: 59, flags: [.maskControl]) == 59)
        #expect(reducer.pressedHardwareKeyCode(for: 59, flags: []) == nil)
        #expect(reducer.pressedHardwareKeyCode(for: 58, flags: [.maskAlternate]) == 58)
        #expect(reducer.pressedHardwareKeyCode(for: 58, flags: []) == nil)
        #expect(reducer.pressedHardwareKeyCode(for: 55, flags: [.maskCommand]) == 55)
        #expect(reducer.pressedHardwareKeyCode(for: 55, flags: []) == nil)
        #expect(reducer.pressedHardwareKeyCode(for: 57, flags: [.maskAlphaShift]) == 57)
        #expect(reducer.pressedHardwareKeyCode(for: 57, flags: []) == 57)
        #expect(reducer.pressedHardwareKeyCode(for: 63, flags: [.maskSecondaryFn]) == 63)
    }

    @Test
    func submissionAnchorIsContentFreeAndOnlyFiresForAllowedReturnKeys() async throws {
        let backend = FakeInputEventTapBackend()
        let accumulator = try makeAccumulator()
        let anchors = LockedCounter()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            submissionAnchorDidOccur: { anchors.increment() }
        )

        await collector.start()
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:01Z"), hardwareKeyCode: 36, isAutoRepeat: false
        ))
        try await eventually { anchors.value == 1 }
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:02Z"), hardwareKeyCode: 36, isAutoRepeat: true
        ))
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:03Z"), hardwareKeyCode: 12, isAutoRepeat: false
        ))
        try await Task.sleep(nanoseconds: 2_000_000)
        #expect(anchors.value == 1)
    }

    @Test
    func foldsPhysicalAndPointerEventsWithoutTextOrderOrApplicationLinkage() async throws {
        let backend = FakeInputEventTapBackend()
        let clock = LockedDate(instant("2026-08-01T00:00:00Z"))
        let accumulator = try makeAccumulator()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            clock: clock
        )

        await collector.start()
        #expect(await backend.startCount == 1)
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:01Z"),
            hardwareKeyCode: 42,
            isAutoRepeat: false
        ))
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:00:02Z"),
            hardwareKeyCode: 42,
            isAutoRepeat: true
        ))
        await backend.emit(.pointerMoved(
            observedAt: instant("2026-08-01T00:00:03Z"),
            point: .init(x: 100, y: 100)
        ))
        await backend.emit(.pointerMoved(
            observedAt: instant("2026-08-01T00:00:04Z"),
            point: .init(x: 200, y: 100)
        ))
        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:00:05Z"),
            point: .init(x: 200, y: 100),
            button: .left
        ))
        await backend.emit(.scroll(
            observedAt: instant("2026-08-01T00:00:06Z"),
            point: .init(x: 200, y: 100),
            deltaX: -3,
            deltaY: 7
        ))

        try await eventually {
            (await accumulator.snapshot()).pendingPeriods.count == 1
        }
        await collector.stop()
        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )

        #expect(aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 42, count: 1)
        ])
        #expect(aggregate.applicationTotals.isEmpty)
        let display = try #require(aggregate.displays.first)
        #expect(display.pointer.clicks.left == 1)
        #expect(display.pointer.scroll.up == 7)
        #expect(display.pointer.scroll.right == 3)
        #expect(display.pointer.scrollEventCount == 1)
        #expect(display.pointer.estimatedDistanceMilliPoints == 100_000)
        #expect(display.grid.cells.reduce(0) { $0 + $1.dwellMilliseconds } == 1_000)
        #expect(aggregate.includedDurationMilliseconds == 5_000)
    }

    @Test
    func foregroundExclusionKeepsPhysicalInputLive() async throws {
        let backend = FakeInputEventTapBackend()
        let accumulator = try makeAccumulator()
        let anchors = LockedCounter()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            submissionAnchorDidOccur: { anchors.increment() }
        )
        await collector.start()
        let firstSession = try #require(await backend.activeSessionID)

        var excluded = allowedGate()
        excluded.foregroundSafety = .excluded
        await collector.updateGate(excluded)

        #expect(await backend.stopCount == 0)
        #expect(await backend.activeSessionID == firstSession)

        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:01:00Z"),
            hardwareKeyCode: 20,
            isAutoRepeat: false
        ))
        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:01:01Z"),
            point: .init(x: 300, y: 200),
            button: .left
        ))
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:01:02Z"),
            hardwareKeyCode: 36,
            isAutoRepeat: false
        ))

        var disabled = excluded
        disabled.keyboard.isEnabled = false
        disabled.pointer.isEnabled = false
        await collector.updateGate(disabled)

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 20, count: 1),
            PhysicalKeyCount(hardwareKeyCode: 36, count: 1),
        ])
        #expect(aggregate.displays.first?.pointer.clicks.left == 1)
        try await eventually { anchors.value == 1 }
    }

    @Test
    func pauseDisableAndLateCallbacksContributeExactlyZero() async throws {
        let backend = FakeInputEventTapBackend()
        let accumulator = try makeAccumulator()
        let collector = makeCollector(accumulator: accumulator, backend: backend)
        await collector.start()
        let firstSession = try #require(await backend.activeSessionID)

        var pointerOnly = allowedGate()
        pointerOnly.keyboard.pauseReasons = [.globalUserPause]
        await collector.updateGate(pointerOnly)
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:02:00Z"),
            hardwareKeyCode: 21,
            isAutoRepeat: false
        ))
        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:02:01Z"),
            point: .init(x: 300, y: 200),
            button: .right
        ))

        var disabled = pointerOnly
        disabled.pointer.isEnabled = false
        await collector.updateGate(disabled)
        await backend.emitLate(
            .keyDown(
                observedAt: instant("2026-08-01T00:03:00Z"),
                hardwareKeyCode: 20,
                isAutoRepeat: false
            ),
            sessionID: firstSession
        )
        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.physicalKeyCounts.isEmpty)
        #expect(aggregate.applicationTotals.isEmpty)
        #expect(aggregate.displays.first?.pointer.clicks.right == 1)
        #expect((await collector.snapshot()).runtime == .unavailable(.productGateClosed))
    }

    @Test
    func missingInputMonitoringNeverStartsAndLiveRevocationStopsWithoutContribution() async throws {
        let backend = FakeInputEventTapBackend()
        let authorization = LockedBoolean(false)
        let accumulator = try makeAccumulator()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            authorizationProbe: authorization.callAsFunction
        )

        await collector.start()
        #expect(await backend.startCount == 0)
        #expect(
            (await collector.snapshot()).runtime
                == .unavailable(.inputMonitoringAuthorizationRequired)
        )

        authorization.set(true)
        await collector.start()
        #expect(await backend.startCount == 1)
        authorization.set(false)
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:03:00Z"),
            hardwareKeyCode: 30,
            isAutoRepeat: false
        ))
        try await eventually { await backend.stopCount == 1 }

        #expect((await accumulator.snapshot()).pendingPeriods.isEmpty)
        #expect(
            (await collector.snapshot()).runtime
                == .unavailable(.inputMonitoringAuthorizationRequired)
        )
    }

    @Test
    func secureInputStopsBeforeContributionAndRecoversWithBoundedBackoff() async throws {
        let backend = FakeInputEventTapBackend()
        let secureInput = SequenceBooleanProbe([false, false, true, false, false, false])
        let accumulator = try makeAccumulator()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            secureInputProbe: secureInput.callAsFunction,
            recoveryDelaysNanoseconds: [0, 0, 0]
        )
        await collector.start()
        var keyboardOnly = allowedGate()
        keyboardOnly.pointer.isEnabled = false
        await collector.updateGate(keyboardOnly)

        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:04:00Z"),
            hardwareKeyCode: 31,
            isAutoRepeat: false
        ))
        try await eventually { await backend.startCount == 2 }
        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:04:01Z"),
            hardwareKeyCode: 32,
            isAutoRepeat: false
        ))
        try await eventually {
            (await accumulator.snapshot()).pendingPeriods.count == 1
        }
        await collector.stop()

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 32, count: 1)
        ])
    }

    @Test
    func secureInputLongerThanInitialBackoffWindowStillRecoversAtTheCappedDelay() async throws {
        let backend = FakeInputEventTapBackend()
        let secureInput = SequenceBooleanProbe([
            false, false, // Initial start and post-start recheck.
            true,        // Event boundary.
            true, true, true, false, // Recovery checks beyond the configured window.
            false, false, // Recovered start and post-start recheck.
        ])
        let collector = makeCollector(
            accumulator: try makeAccumulator(),
            backend: backend,
            secureInputProbe: secureInput.callAsFunction,
            recoveryDelaysNanoseconds: [1_000_000, 1_000_000]
        )
        await collector.start()
        var keyboardOnly = allowedGate()
        keyboardOnly.pointer.isEnabled = false
        await collector.updateGate(keyboardOnly)
        await backend.emit(.secureInputBegan)

        try await eventually {
            let startCount = await backend.startCount
            let runtime = await collector.snapshot().runtime
            return startCount == 2 && runtime == .running
        }
        await collector.stop()
    }

    @Test
    func secureInputSuppressesKeysButLeavesPointerAggregationRunning() async throws {
        let backend = FakeInputEventTapBackend()
        let secureInput = LockedBoolean(true)
        let accumulator = try makeAccumulator()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            secureInputProbe: secureInput.callAsFunction
        )
        await collector.start()

        await backend.emit(.keyDown(
            observedAt: instant("2026-08-01T00:04:00Z"),
            hardwareKeyCode: 31,
            isAutoRepeat: false
        ))
        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:04:01Z"),
            point: .init(x: 100, y: 100),
            button: .left
        ))
        try await eventually {
            (await accumulator.snapshot()).pendingPeriods.count == 1
        }
        await collector.stop()

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.physicalKeyCounts.isEmpty)
        #expect(aggregate.displays.first?.pointer.clicks.left == 1)
    }

    @Test
    func disabledTapRetriesOnlyTheConfiguredNumberOfTimes() async throws {
        let backend = FakeInputEventTapBackend()
        let collector = makeCollector(
            accumulator: try makeAccumulator(),
            backend: backend,
            recoveryDelaysNanoseconds: [0, 0, 0]
        )
        await collector.start()
        await backend.setStartFailureEnabled(true)
        await backend.emit(.tapDisabled)

        try await eventually {
            let startCount = await backend.startCount
            let runtime = await collector.snapshot().runtime
            return startCount == 4 && runtime == .unavailable(.backendUnavailable)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(await backend.startCount == 4)
    }

    @Test
    func overlappingDisplayRegionsFailClosedWithoutHeatMapContribution() async throws {
        let backend = FakeInputEventTapBackend()
        let first = displayRegion("AAAAAAAA-0000-0000-0000-000000000001")
        let second = displayRegion("BBBBBBBB-0000-0000-0000-000000000002")
        let provider = StaticInputDisplayRegions([first, second])
        let accumulator = try makeAccumulator()
        let collector = makeCollector(
            accumulator: accumulator,
            backend: backend,
            displayRegions: provider
        )
        await collector.start()
        await backend.emit(.pointerButtonDown(
            observedAt: instant("2026-08-01T00:05:00Z"),
            point: .init(x: 50, y: 50),
            button: .left
        ))
        await collector.stop()

        #expect((await accumulator.snapshot()).pendingPeriods.isEmpty)
    }
}

private actor FakeInputEventTapBackend: InputEventTapBackend {
    enum Failure: Error { case configured }

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeSessionID: UInt64?
    private var startFailureEnabled = false
    private var activeHandler: (@Sendable ([TransientInputEvent]) async -> Void)?
    private var handlers: [UInt64: @Sendable ([TransientInputEvent]) async -> Void] = [:]

    func start(
        sessionID: UInt64,
        handler: @escaping @Sendable ([TransientInputEvent]) async -> Void
    ) async throws {
        startCount += 1
        if startFailureEnabled { throw Failure.configured }
        activeSessionID = sessionID
        activeHandler = handler
        handlers[sessionID] = handler
    }

    func stop(sessionID: UInt64) async {
        stopCount += 1
        if activeSessionID == sessionID {
            activeSessionID = nil
            activeHandler = nil
        }
    }

    func emit(_ event: TransientInputEvent) async {
        await activeHandler?([event])
    }

    func emitLate(_ event: TransientInputEvent, sessionID: UInt64) async {
        await handlers[sessionID]?([event])
    }

    func setStartFailureEnabled(_ enabled: Bool) {
        startFailureEnabled = enabled
    }
}

private struct StaticInputDisplayRegions: InputDisplayRegionProviding {
    let regions: [InputDisplayRegion]

    init(_ regions: [InputDisplayRegion]) {
        self.regions = regions
    }

    func currentRegions() -> [InputDisplayRegion] { regions }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func set(_ value: Bool) {
        lock.withLock { self.value = value }
    }

    func callAsFunction() -> Bool {
        lock.withLock { value }
    }
}

private final class SequenceBooleanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) { self.values = values }

    func callAsFunction() -> Bool {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? false }
            return values.removeFirst()
        }
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }

    func callAsFunction() -> Date {
        lock.withLock { value }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private func makeCollector(
    accumulator: InputAggregationAccumulator,
    backend: FakeInputEventTapBackend,
    displayRegions: any InputDisplayRegionProviding = StaticInputDisplayRegions([
        displayRegion("AAAAAAAA-0000-0000-0000-000000000001")
    ]),
    clock: LockedDate = LockedDate(instant("2026-08-01T00:00:00Z")),
    authorizationProbe: @escaping @Sendable () -> Bool = { true },
    secureInputProbe: @escaping @Sendable () -> Bool = { false },
    recoveryDelaysNanoseconds: [UInt64] = [0, 0, 0],
    aggregateDidChange: @escaping @Sendable () async -> Void = {},
    submissionAnchorDidOccur: @escaping @Sendable () async -> Void = {}
) -> CGEventTapInputCollector {
    CGEventTapInputCollector(
        accumulator: accumulator,
        backend: backend,
        displayRegions: displayRegions,
        initialGate: allowedGate(),
        inputMonitoringPreflight: authorizationProbe,
        secureInputPreflight: secureInputProbe,
        clock: clock.callAsFunction,
        recoveryDelaysNanoseconds: recoveryDelaysNanoseconds,
        aggregateDidChange: aggregateDidChange,
        submissionAnchorDidOccur: submissionAnchorDidOccur
    )
}

private func allowedGate() -> InputCollectionGate {
    InputCollectionGate(
        keyboard: .init(isEnabled: true, authorization: .authorized),
        pointer: .init(isEnabled: true, authorization: .authorized),
        isUserSessionAvailable: true,
        foregroundSafety: .allowed
    )
}

private func makeAccumulator() throws -> InputAggregationAccumulator {
    InputAggregationAccumulator(configuration: try .init(
        timeZoneIdentifier: "UTC",
        collectorVersion: "input-tap-v1",
        defaultLayoutVersion: "physical-v1"
    ))
}

private func displayRegion(_ id: String) -> InputDisplayRegion {
    InputDisplayRegion(
        display: DisplayContext(
            id: DisplayID(rawValue: UUID(uuidString: id)!),
            topologyRevision: 1
        ),
        bounds: DisplayBounds(x: 0, y: 0, width: 1_000, height: 800)
    )
}

private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func eventually(
    attempts: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Condition was not met")
}
