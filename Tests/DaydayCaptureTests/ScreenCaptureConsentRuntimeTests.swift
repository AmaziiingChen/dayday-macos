@testable import DaydayCapture
import DaydayCore
import Foundation
import Testing

@Suite("Screen capture consent runtime", .serialized)
struct ScreenCaptureConsentRuntimeTests {
    @Test("enabled consent, authorization, session and target are all required")
    func allGatesAreRequired() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let preflight = RuntimeAuthorizationPreflight(.notAuthorized)
        let runtime = try makeRuntime(backend: backend, preflight: preflight, outputs: outputs)

        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await runtime.setSessionAvailable(true)
        #expect(await backend.startCount == 0)

        preflight.set(.authorized)
        await runtime.refreshAuthorization()
        try await waitUntil { outputs.hasReached(.available) }
        #expect(await backend.startCount == 1)
        await runtime.shutdown()
    }

    @Test("pause and disable invalidate the lease and actively stop capture")
    func pauseAndDisableStopCapture() async throws {
        for terminalStatus in [CollectorConsentStatus.paused, .disabled] {
            let backend = RuntimeScreenBackend()
            let outputs = RuntimeOutputRecorder()
            let runtime = try makeRuntime(backend: backend, outputs: outputs)
            let enabled = try enabledScreenConsent()
            try await runtime.updateConsent(enabled)
            await runtime.setDisplayTarget(makeTarget())
            await runtime.setSessionAvailable(true)
            try await waitUntil { outputs.hasReached(.available) }
            #expect(await backend.startCount == 1)

            let updated = try transition(from: enabled, to: terminalStatus)
            try await runtime.updateConsent(updated)

            #expect(await backend.stopCount == 1)
            #expect(await backend.sessionIsStopped)
            #expect((await runtime.snapshot()).consentStatus == terminalStatus)
            await runtime.shutdown()
        }
    }

    @Test("an unavailable session stops and recovery gets a fresh one-use start")
    func sessionUnavailabilityStopsAndRecovers() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await runtime.setSessionAvailable(true)
        try await waitUntil { outputs.hasReached(.available) }

        await runtime.setSessionAvailable(false)
        #expect(await backend.stopCount == 1)
        #expect(await backend.sessionIsStopped)
        #expect(outputs.availabilities.last == .hardUnavailable(.sessionUnavailable))

        await runtime.setSessionAvailable(true)
        try await waitUntil { outputs.hasReached(.available, times: 2) }
        #expect(await backend.startCount == 2)
        await runtime.shutdown()
    }

    @Test("automatic nonprompting monitor stops on TCC revocation and restarts on recovery")
    func authorizationMonitorStopsAndRecovers() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let preflight = RuntimeAuthorizationPreflight(.authorized)
        let runtime = try makeRuntime(
            backend: backend,
            preflight: preflight,
            outputs: outputs,
            monitorInterval: .milliseconds(5)
        )
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await runtime.setSessionAvailable(true)
        try await waitUntil { outputs.hasReached(.available) }
        #expect(await backend.startCount == 1)

        preflight.set(.notAuthorized)
        try await eventually { await backend.stopCount == 1 }
        #expect(await backend.sessionIsStopped)
        #expect((await runtime.snapshot()).screenRecordingAuthorization == .notAuthorized)

        preflight.set(.authorized)
        try await eventually { await backend.startCount == 2 }
        try await waitUntil { outputs.hasReached(.available, times: 2) }
        await runtime.shutdown()
    }

    @Test("pause wins when backend start is suspended")
    func pauseWinsAgainstInFlightStart() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        let enabled = try enabledScreenConsent()
        try await runtime.updateConsent(enabled)
        await runtime.setDisplayTarget(makeTarget())
        await backend.blockNextStart()

        let start = Task { await runtime.setSessionAvailable(true) }
        await backend.waitUntilStartEntered()
        try await runtime.updateConsent(try transition(from: enabled, to: .paused))
        await backend.releaseBlockedStart()
        await start.value

        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(await backend.sessionIsStopped)
        #expect(!outputs.availabilities.contains(.available))
        await runtime.shutdown()
    }

    @Test("session loss wins when backend start is suspended")
    func sessionLossWinsAgainstInFlightStart() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await backend.blockNextStart()

        let start = Task { await runtime.setSessionAvailable(true) }
        await backend.waitUntilStartEntered()
        await runtime.setSessionAvailable(false)
        await backend.releaseBlockedStart()
        await start.value

        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(await backend.sessionIsStopped)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.last == .hardUnavailable(.sessionUnavailable))
        await runtime.shutdown()
    }

    @Test("target clear wins when backend start is suspended")
    func targetClearWinsAgainstInFlightStart() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await backend.blockNextStart()

        await runtime.setSessionAvailable(true)
        await backend.waitUntilStartEntered()
        await runtime.setDisplayTarget(nil)
        await backend.releaseBlockedStart()

        try await eventually { await backend.sessionIsStopped }
        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.last == .idle)
        #expect(!(await runtime.snapshot()).hasDisplayTarget)
        await runtime.shutdown()
    }

    @Test("shutdown wins when backend start is suspended")
    func shutdownWinsAgainstInFlightStart() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await backend.blockNextStart()

        await runtime.setSessionAvailable(true)
        await backend.waitUntilStartEntered()
        await runtime.shutdown()
        await backend.releaseBlockedStart()

        try await eventually { await backend.sessionIsStopped }
        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.last == .idle)
    }

    @Test("TCC revocation wins when backend start is suspended")
    func authorizationLossWinsAgainstInFlightStart() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let preflight = RuntimeAuthorizationPreflight(.authorized)
        let runtime = try makeRuntime(
            backend: backend,
            preflight: preflight,
            outputs: outputs
        )
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await backend.blockNextStart()

        let start = Task { await runtime.setSessionAvailable(true) }
        await backend.waitUntilStartEntered()
        preflight.set(.notAuthorized)
        await runtime.refreshAuthorization()
        await backend.releaseBlockedStart()
        await start.value

        #expect(await backend.startCount == 1)
        try await eventually { outputs.availabilities.last == .hardUnavailable(.authorizationRequired) }
        #expect(await backend.stopCount == 1)
        #expect(await backend.sessionIsStopped)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.last == .hardUnavailable(.authorizationRequired))
        await runtime.shutdown()
    }

    @Test("clearing target and shutdown are idempotent hard boundaries")
    func targetClearAndShutdownAreIdempotent() async throws {
        let backend = RuntimeScreenBackend()
        let outputs = RuntimeOutputRecorder()
        let runtime = try makeRuntime(backend: backend, outputs: outputs)
        try await runtime.updateConsent(enabledScreenConsent())
        await runtime.setDisplayTarget(makeTarget())
        await runtime.setSessionAvailable(true)
        try await waitUntil { outputs.hasReached(.available) }

        await runtime.setDisplayTarget(nil)
        await runtime.setDisplayTarget(nil)
        #expect(await backend.stopCount == 1)
        #expect(await backend.sessionIsStopped)

        await runtime.setDisplayTarget(makeTarget())
        try await waitUntil { outputs.hasReached(.available, times: 2) }
        #expect(await backend.startCount == 2)
        await runtime.shutdown()
        await runtime.shutdown()
        #expect(await backend.stopCount == 2)
        #expect(await backend.sessionIsStopped)
    }

    @Test("foreign collector consent is rejected without changing screen state")
    func foreignConsentIsRejected() async throws {
        let backend = RuntimeScreenBackend()
        let runtime = try makeRuntime(backend: backend)
        let weather = try enabledConsent(for: .weather)

        await #expect(throws: ScreenCaptureConsentRuntimeError.collectorMismatch) {
            try await runtime.updateConsent(weather)
        }
        #expect((await runtime.snapshot()).consentStatus == .unconfirmed)
        #expect(await backend.startCount == 0)
        await runtime.shutdown()
    }

    @Test("public Capture API has no lease, tokenized start, or prompt seam")
    func publicAPIOwnsLeaseInsideRuntime() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let streamSource = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/DaydayCapture/ScreenCaptureStream.swift"
            ),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/DaydayCapture/ScreenCaptureConsentRuntime.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "public final class ScreenCaptureConsentLease",
            "public struct ScreenCaptureStartAuthorization",
            "public struct ScreenCaptureStartAuthorizationGate",
            "public func start(\n        display target",
            "PermissionRequesting",
            "CGRequestScreenCaptureAccess",
        ] {
            #expect(!streamSource.contains(forbidden))
            #expect(!runtimeSource.contains(forbidden))
        }
        #expect(runtimeSource.contains("private let consentLease"))
        #expect(runtimeSource.contains("private let authorizationGate"))
    }

    private func makeRuntime(
        backend: RuntimeScreenBackend,
        preflight: RuntimeAuthorizationPreflight = RuntimeAuthorizationPreflight(.authorized),
        outputs: RuntimeOutputRecorder = RuntimeOutputRecorder(),
        monitorInterval: Duration = .seconds(30)
    ) throws -> ScreenCaptureConsentRuntime {
        let stream = ScreenCaptureStream(
            backend: backend,
            clock: { Date(timeIntervalSinceReferenceDate: 500) },
            processor: { _ in nil },
            outputHandler: outputs.record
        )
        return try ScreenCaptureConsentRuntime(
            preflight: preflight,
            stream: stream,
            clock: { Date(timeIntervalSinceReferenceDate: 500) },
            authorizationMonitorInterval: monitorInterval
        )
    }

    private func makeTarget() -> ScreenCaptureDisplayTarget {
        ScreenCaptureDisplayTarget(
            display: DisplayContext(
                id: DisplayID(rawValue: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                topologyRevision: 8
            ),
            runtimeDisplayID: 88
        )
    }

    private func enabledScreenConsent() throws -> CollectorConsent {
        try enabledConsent(for: .screenUnderstanding)
    }

    private func enabledConsent(for collector: CollectorKind) throws -> CollectorConsent {
        let confirmation = try UserConsentConfirmation(
            collector: collector,
            confirmedAt: Date(timeIntervalSinceReferenceDate: 100),
            disclosureVersion: "runtime-v1"
        )
        return try CollectorConsentStateMachine.transition(
            .enable(confirmation),
            from: CollectorConsent(collector: collector)
        )
    }

    private func transition(
        from consent: CollectorConsent,
        to status: CollectorConsentStatus
    ) throws -> CollectorConsent {
        let confirmation = try UserConsentConfirmation(
            collector: .screenUnderstanding,
            confirmedAt: Date(timeIntervalSinceReferenceDate: 200),
            disclosureVersion: "runtime-v1"
        )
        switch status {
        case .paused:
            return try CollectorConsentStateMachine.transition(.pause(confirmation), from: consent)
        case .disabled:
            return try CollectorConsentStateMachine.transition(.disable(confirmation), from: consent)
        case .enabled, .unconfirmed:
            preconditionFailure("Test helper supports only terminal consent states")
        }
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw RuntimeTestError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await eventually(timeout: timeout, condition: condition)
    }
}

private actor RuntimeScreenBackend: ScreenCaptureStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var currentSessionID: UInt64?
    private var shouldBlockNextStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var sessionIsStopped: Bool { currentSessionID == nil }

    func start(
        sessionID: UInt64,
        runtimeDisplayID: UInt32,
        callbacks: ScreenCaptureBackendCallbacks
    ) async throws {
        startCount += 1
        currentSessionID = sessionID
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            await withCheckedContinuation { startContinuation = $0 }
        }
    }

    func stop(sessionID: UInt64) async {
        guard currentSessionID == sessionID else { return }
        currentSessionID = nil
        stopCount += 1
    }

    func blockNextStart() {
        shouldBlockNextStart = true
    }

    func waitUntilStartEntered() async {
        guard startCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

private final class RuntimeAuthorizationPreflight: @unchecked Sendable,
    CaptureAuthorizationPreflighting {
    private let lock = NSLock()
    private var state: CaptureAuthorizationPreflightState

    init(_ state: CaptureAuthorizationPreflightState) {
        self.state = state
    }

    func snapshot(at date: Date) -> CaptureAuthorizationSnapshot {
        CaptureAuthorizationSnapshot(
            screenRecording: lock.withLock { state },
            accessibility: .authorized,
            checkedAt: date
        )
    }

    func set(_ state: CaptureAuthorizationPreflightState) {
        lock.withLock { self.state = state }
    }
}

private final class RuntimeOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [ScreenCaptureStreamOutput] = []

    var availabilities: [ScreenCaptureAvailability] {
        lock.withLock {
            outputs.compactMap {
                guard case let .availability(fact) = $0 else { return nil }
                return fact.availability
            }
        }
    }

    func count(of availability: ScreenCaptureAvailability) -> Int {
        availabilities.filter { $0 == availability }.count
    }

    func hasReached(_ availability: ScreenCaptureAvailability, times: Int = 1) -> Bool {
        count(of: availability) >= times
    }

    func record(_ output: ScreenCaptureStreamOutput) {
        lock.withLock { outputs.append(output) }
    }
}

private enum RuntimeTestError: Error {
    case timeout
}
