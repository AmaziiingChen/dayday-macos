@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
@testable import DaydayCapture
import DaydayCore
import Foundation
import Testing

struct ScreenCaptureStreamTests {
    @Test
    func startStopAndRestartAreIdempotent() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let target = makeTarget()

        await start(stream, display: target, authorization: try makeAuthorization())
        await start(stream, display: target, authorization: try makeAuthorization())
        #expect(await backend.startCount == 1)

        await stream.stop()
        await stream.stop()
        #expect(await backend.stopCount == 1)

        await start(stream, display: target, authorization: try makeAuthorization())
        #expect(await backend.startCount == 2)
        #expect(outputs.availabilities == [
            .starting, .available, .idle, .starting, .available
        ])
    }

    @Test
    func lateFramesAfterStopAndSessionSuppressionAreNeverDelivered() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let target = makeTarget()

        await start(stream, display: target, authorization: try makeAuthorization())
        let firstCallbacks = try #require(await backend.currentCallbacks)
        await stream.stop()
        firstCallbacks.frame(try makeSample(width: 11, height: 7))

        await start(stream, display: target, authorization: try makeAuthorization())
        let secondCallbacks = try #require(await backend.currentCallbacks)
        await stream.suspendForUnavailableSession()
        secondCallbacks.frame(try makeSample(width: 13, height: 9))

        try await eventually { outputs.frameMetadata.isEmpty }
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.sessionUnavailable)])
    }

    @Test
    func sessionSuppressionStopsAndFreshAuthorizationRecovers() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let target = makeTarget()

        await start(stream, display: target, authorization: try makeAuthorization())
        await stream.suspendForUnavailableSession()
        #expect(await backend.stopCount == 1)
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.sessionUnavailable)])

        await start(stream, display: target, authorization: try makeAuthorization())
        #expect(await backend.startCount == 2)
        #expect(outputs.availabilities.suffix(2) == [.starting, .available])
    }

    @Test
    func idleStopInvalidatesAStartCapturedBeforeTheBoundary() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let staleRevocationCount = await stream.currentRevocationCount

        await stream.stop()
        await stream.start(
            display: makeTarget(),
            authorization: try makeAuthorization(),
            revokedAt: staleRevocationCount
        )

        #expect(await backend.startCount == 0)
        #expect(await backend.stopInvocationCount == 0)
        #expect(outputs.availabilities.isEmpty)
    }

    @Test
    func productConsentAndInitialPreflightFailClosedBeforeBackend() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        _ = makeStream(backend: backend, outputs: outputs)
        let deniedPreflight = MutableCaptureAuthorizationPreflight(screenRecording: .notAuthorized)
        let missingConsentLease = try ScreenCaptureConsentLease(
            consent: CollectorConsent(collector: .screenUnderstanding)
        )
        let missingConsentGate = ScreenCaptureStartAuthorizationGate(
            consentLease: missingConsentLease,
            preflight: deniedPreflight
        )

        let missingConsent = missingConsentGate.authorizeStart()
        guard case let .denied(missingConsentReason) = missingConsent else {
            Issue.record("Unconfirmed consent must not issue a start authorization")
            return
        }
        #expect(missingConsentReason == .productConsentRequired)

        let enabledLease = try ScreenCaptureConsentLease(consent: enabledScreenConsent())
        let deniedGate = ScreenCaptureStartAuthorizationGate(
            consentLease: enabledLease,
            preflight: deniedPreflight
        )
        let deniedSystem = deniedGate.authorizeStart()
        guard case let .denied(systemReason) = deniedSystem else {
            Issue.record("A denied system preflight must not issue a start authorization")
            return
        }
        #expect(systemReason == .screenRecordingAuthorizationRequired)
        #expect(await backend.startCount == 0)
        #expect(await backend.stopInvocationCount == 0)
    }

    @Test
    func authorizationRevokedAfterIssuanceNeverCallsBackend() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let preflight = MutableCaptureAuthorizationPreflight(screenRecording: .authorized)
        let authorization = try makeAuthorization(preflight: preflight)

        preflight.setScreenRecording(.notAuthorized)
        await start(stream, display: makeTarget(), authorization: authorization)

        #expect(await backend.startCount == 0)
        #expect(await backend.stopInvocationCount == 0)
        #expect(outputs.availabilities == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func authorizationRevokedWhileReplacingStreamNeverStartsNewBackend() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let preflight = MutableCaptureAuthorizationPreflight(screenRecording: .authorized)

        await start(
            stream,
            display: makeTarget(topologyRevision: 1),
            authorization: try makeAuthorization(preflight: preflight)
        )
        await backend.setStopHook {
            preflight.setScreenRecording(.notAuthorized)
        }
        let replacementAuthorization = try makeAuthorization(preflight: preflight)

        await start(
            stream,
            display: makeTarget(topologyRevision: 2),
            authorization: replacementAuthorization
        )

        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func productConsentPausedAfterIssuanceNeverCallsBackend() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let consentLease = try ScreenCaptureConsentLease(consent: enabledScreenConsent())
        let authorization = try makeAuthorization(consentLease: consentLease)

        try consentLease.update(pausedScreenConsent())
        await start(stream, display: makeTarget(), authorization: authorization)

        #expect(await backend.startCount == 0)
        #expect(await backend.stopInvocationCount == 0)
        #expect(outputs.availabilities == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func consentRevokedDuringSuccessfulBackendStartNeverPublishesAvailable() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let consentLease = try ScreenCaptureConsentLease(consent: enabledScreenConsent())
        let authorization = try makeAuthorization(consentLease: consentLease)

        await backend.blockNextStart()
        let revokedAt = await stream.currentRevocationCount
        let startTask = Task {
            await stream.start(
                display: makeTarget(),
                authorization: authorization,
                revokedAt: revokedAt
            )
        }
        await backend.waitUntilStartEntered()
        try consentLease.update(pausedScreenConsent())
        await backend.releaseBlockedStart()
        await startTask.value

        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func systemAuthorizationRevokedDuringSuccessfulBackendStartNeverPublishesAvailable() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let preflight = MutableCaptureAuthorizationPreflight(screenRecording: .authorized)
        let authorization = try makeAuthorization(preflight: preflight)

        await backend.blockNextStart()
        let revokedAt = await stream.currentRevocationCount
        let startTask = Task {
            await stream.start(
                display: makeTarget(),
                authorization: authorization,
                revokedAt: revokedAt
            )
        }
        await backend.waitUntilStartEntered()
        preflight.setScreenRecording(.notAuthorized)
        await backend.releaseBlockedStart()
        await startTask.value

        #expect(await backend.startCount == 1)
        #expect(await backend.stopCount == 1)
        #expect(!outputs.availabilities.contains(.available))
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func startAuthorizationIsSingleUse() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let authorization = try makeAuthorization()

        await start(stream, display: makeTarget(), authorization: authorization)
        await stream.stop()
        await start(stream, display: makeTarget(), authorization: authorization)

        #expect(await backend.startCount == 1)
        #expect(outputs.availabilities.suffix(1) == [.hardUnavailable(.authorizationRequired)])
    }

    @Test
    func backpressureKeepsOnlyLatestPendingFrameAndOneInFlight() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let processor = BlockingProcessor()
        let stream = makeStream(
            backend: backend,
            outputs: outputs,
            processor: { frame in
                processor.process(frame)
                return nil
            }
        )

        await start(stream, display: makeTarget(), authorization: try makeAuthorization())
        await backend.emit(try makeSample(width: 10, height: 10))
        try await eventually { processor.startedCount == 1 }

        await backend.emit(try makeSample(width: 20, height: 10))
        await backend.emit(try makeSample(width: 30, height: 10))
        processor.releaseFirst()

        try await eventually { processor.processedWidths == [10, 30] }
        try await eventually { outputs.frameMetadata.map(\.pixelWidth) == [10, 30] }
        #expect(processor.maximumConcurrentCount == 1)
    }

    @Test
    func stoppingCaptureCancelsInFlightVisionRecognition() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let recognizer = CancelBlockingScreenTextRecognizer()
        let processor = LocalScreenOCRProcessor(
            recognizer: recognizer,
            safetyGate: AlwaysPermittedScreenOCRSafetyGate(),
            minimumInterval: 0
        )
        let stream = ScreenCaptureStream(
            backend: backend,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            localOCRProcessor: processor,
            outputHandler: { output in outputs.record(output) }
        )

        await start(stream, display: makeTarget(), authorization: try makeAuthorization())
        await backend.emit(try makeSample(width: 32, height: 18))
        try await eventually { recognizer.isRecognizing }

        await stream.stop()

        #expect(recognizer.cancellationCount == 1)
        try await eventually { !recognizer.isRecognizing }
        #expect(outputs.availabilities.suffix(1) == [.idle])
    }

    @Test
    func backendFailurePublishesHardUnavailableAndCanRecover() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let target = makeTarget()

        await start(stream, display: target, authorization: try makeAuthorization())
        await backend.terminate(.failed)
        try await eventually {
            outputs.availabilities.last == .hardUnavailable(.streamFailed)
        }

        await start(stream, display: target, authorization: try makeAuthorization())
        #expect(await backend.startCount == 2)
        #expect(outputs.availabilities.suffix(2) == [.starting, .available])
    }

    @Test
    func backendStopPublishesHardUnavailableInsteadOfSilentIdle() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)

        await start(stream, display: makeTarget(), authorization: try makeAuthorization())
        await backend.terminate(.stopped)

        try await eventually {
            outputs.availabilities.last == .hardUnavailable(.streamStopped)
        }
    }

    @Test
    func metadataCarriesOpaqueDisplayIdentityAndTopologyRevision() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let stream = makeStream(backend: backend, outputs: outputs)
        let target = makeTarget(topologyRevision: 77)

        await start(stream, display: target, authorization: try makeAuthorization())
        await backend.emit(try makeSample(width: 40, height: 25))

        try await eventually { outputs.frameMetadata.count == 1 }
        #expect(outputs.frameMetadata.first?.display == target.display)
        #expect(outputs.frameMetadata.first?.pixelWidth == 40)
        #expect(outputs.frameMetadata.first?.pixelHeight == 25)
    }

    @Test
    func redactedOCRResultIsDeliveredOnlyThroughTheActiveGeneration() async throws {
        let backend = FakeScreenCaptureBackend()
        let outputs = OutputRecorder()
        let line = try RedactedOCRLine("Visible document text")
        let derivative = PreparedScreenVisionDerivative(
            encodedJPEG: Data([0xFF, 0xD8, 0xFF]),
            pixelWidth: 80,
            pixelHeight: 50
        )
        let stream = makeStream(
            backend: backend,
            outputs: outputs,
            processor: { _ in
                EphemeralFrameAnalysis(
                    lines: [line],
                    redactionApplied: true,
                    visionDerivative: derivative
                )
            }
        )
        let target = makeTarget(topologyRevision: 88)

        await start(stream, display: target, authorization: try makeAuthorization())
        await backend.emit(try makeSample(width: 80, height: 50))

        try await eventually { outputs.recognizedText.count == 1 }
        #expect(outputs.recognizedText.first?.frame.display == target.display)
        #expect(outputs.recognizedText.first?.lines == [line])
        #expect(outputs.recognizedText.first?.redactionApplied == true)
        #expect(outputs.visionDerivatives.count == 1)
        #expect(outputs.visionDerivatives.first?.redactedOCRLines == [line])

        await stream.stop()
        await backend.emit(try makeSample(width: 90, height: 60))
        try await Task.sleep(for: .milliseconds(50))
        #expect(outputs.recognizedText.count == 1)
        #expect(outputs.visionDerivatives.count == 1)
    }

    @Test
    func publicApiAndImplementationHaveNoPersistenceSurface() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repository
            .appendingPathComponent("Sources")
            .appendingPathComponent("DaydayCapture")
        let sources = try ["EphemeralScreenFrame.swift", "ScreenCaptureStream.swift"].map {
            try String(contentsOf: sourceDirectory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        for forbidden in [
            "FileManager", "FileHandle", "temporaryDirectory", ": Codable", ".write("
        ] {
            #expect(!sources.contains(forbidden))
        }

        for line in sources.split(separator: "\n") where line.contains("public") {
            #expect(!line.contains("CMSampleBuffer"))
            #expect(!line.contains("CVPixelBuffer"))
            #expect(!line.contains("CapturedScreenSample"))
            #expect(!line.contains("EphemeralScreenFrame"))
        }
        #expect(sources.contains("authorization: ScreenCaptureStartAuthorization"))
        #expect(!sources.contains("public func screenDidLock"))
        #expect(!sources.contains("case screenLocked"))
    }

    @Test
    func applicationBundleDeclaresScreenCapturePurpose() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistData = try Data(contentsOf: repository
            .appendingPathComponent("Config")
            .appendingPathComponent("Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )
        let purpose = try #require(plist["NSScreenCaptureUsageDescription"] as? String)

        #expect(!purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func enabledScreenConsent() throws -> CollectorConsent {
        let confirmation = try UserConsentConfirmation(
            collector: .screenUnderstanding,
            confirmedAt: Date(timeIntervalSince1970: 1_800_000_000),
            disclosureVersion: "1"
        )
        return try CollectorConsentStateMachine.transition(
            .enable(confirmation),
            from: CollectorConsent(collector: .screenUnderstanding)
        )
    }

    private func pausedScreenConsent() throws -> CollectorConsent {
        let enabled = try enabledScreenConsent()
        let confirmation = try UserConsentConfirmation(
            collector: .screenUnderstanding,
            confirmedAt: Date(timeIntervalSince1970: 1_800_000_001),
            disclosureVersion: "1"
        )
        return try CollectorConsentStateMachine.transition(.pause(confirmation), from: enabled)
    }

    private func makeAuthorization(
        preflight: any CaptureAuthorizationPreflighting = MutableCaptureAuthorizationPreflight(
            screenRecording: .authorized
        ),
        consentLease: ScreenCaptureConsentLease? = nil
    ) throws -> ScreenCaptureStartAuthorization {
        let lease = try consentLease ?? ScreenCaptureConsentLease(
            consent: enabledScreenConsent()
        )
        let gate = ScreenCaptureStartAuthorizationGate(
            consentLease: lease,
            preflight: preflight
        )
        switch gate.authorizeStart() {
        case let .authorized(authorization):
            return authorization
        case let .denied(reason):
            throw TestFrameError.authorizationDenied(reason)
        }
    }

    private func start(
        _ stream: ScreenCaptureStream,
        display target: ScreenCaptureDisplayTarget,
        authorization: ScreenCaptureStartAuthorization
    ) async {
        let revokedAt = await stream.currentRevocationCount
        await stream.start(
            display: target,
            authorization: authorization,
            revokedAt: revokedAt
        )
    }

    private func makeStream(
        backend: FakeScreenCaptureBackend,
        outputs: OutputRecorder,
        processor: @escaping EphemeralFramePump.Processor = { frame in
            _ = frame.withPixelBuffer { _ in () }
            return nil
        }
    ) -> ScreenCaptureStream {
        ScreenCaptureStream(
            backend: backend,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            processor: processor,
            outputHandler: { output in outputs.record(output) }
        )
    }

    private func makeTarget(topologyRevision: UInt64 = 5) -> ScreenCaptureDisplayTarget {
        ScreenCaptureDisplayTarget(
            display: DisplayContext(
                id: DisplayID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                topologyRevision: topologyRevision
            ),
            runtimeDisplayID: 42
        )
    }

    private func makeSample(width: Int, height: Int) throws -> CapturedScreenSample {
        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw TestFrameError.pixelBufferCreationFailed(pixelStatus)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestFrameError.formatDescriptionCreationFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestFrameError.sampleBufferCreationFailed(sampleStatus)
        }
        return CapturedScreenSample(sampleBuffer: sampleBuffer)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestFrameError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor FakeScreenCaptureBackend: ScreenCaptureStreamBackend {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopInvocationCount = 0
    private var stopHook: (@Sendable () -> Void)?
    private var shouldBlockNextStart = false
    private var blockedStartContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        sessionID: UInt64,
        runtimeDisplayID: UInt32,
        callbacks: ScreenCaptureBackendCallbacks
    ) async throws {
        startCount += 1
        current = (sessionID, callbacks)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if shouldBlockNextStart {
            shouldBlockNextStart = false
            await withCheckedContinuation { continuation in
                blockedStartContinuation = continuation
            }
        }
    }

    func stop(sessionID: UInt64) async {
        stopInvocationCount += 1
        guard current?.0 == sessionID else { return }
        stopCount += 1
        current = nil
        stopHook?()
    }

    func setStopHook(_ hook: @escaping @Sendable () -> Void) {
        stopHook = hook
    }

    func blockNextStart() {
        shouldBlockNextStart = true
    }

    func waitUntilStartEntered() async {
        guard startCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedStart() {
        blockedStartContinuation?.resume()
        blockedStartContinuation = nil
    }

    func emit(_ sample: CapturedScreenSample) {
        current?.1.frame(sample)
    }

    func terminate(_ reason: ScreenCaptureBackendTermination) {
        current?.1.terminated(reason)
    }

    var currentCallbacks: ScreenCaptureBackendCallbacks? { current?.1 }

    private var current: (UInt64, ScreenCaptureBackendCallbacks)?
}

private final class MutableCaptureAuthorizationPreflight: @unchecked Sendable,
    CaptureAuthorizationPreflighting {
    private let lock = NSLock()
    private var screenRecording: CaptureAuthorizationPreflightState

    init(screenRecording: CaptureAuthorizationPreflightState) {
        self.screenRecording = screenRecording
    }

    func snapshot(at date: Date) -> CaptureAuthorizationSnapshot {
        CaptureAuthorizationSnapshot(
            screenRecording: lock.withLock { screenRecording },
            accessibility: .authorized,
            checkedAt: date
        )
    }

    func setScreenRecording(_ state: CaptureAuthorizationPreflightState) {
        lock.withLock { screenRecording = state }
    }
}

private final class OutputRecorder: @unchecked Sendable {
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

    var frameMetadata: [ObjectiveScreenFrameMetadata] {
        lock.withLock {
            outputs.compactMap {
                guard case let .frame(metadata) = $0 else { return nil }
                return metadata
            }
        }
    }

    var recognizedText: [ObjectiveScreenTextObservation] {
        lock.withLock {
            outputs.compactMap {
                guard case let .recognizedText(observation) = $0 else { return nil }
                return observation
            }
        }
    }

    var visionDerivatives: [ObjectiveScreenVisionDerivative] {
        lock.withLock {
            outputs.compactMap {
                guard case let .visionDerivative(derivative) = $0 else { return nil }
                return derivative
            }
        }
    }

    func record(_ output: ScreenCaptureStreamOutput) {
        lock.withLock { outputs.append(output) }
    }
}

private final class BlockingProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private let firstGate = DispatchSemaphore(value: 0)
    private var widths: [Int] = []
    private var currentCount = 0
    private var maximumCount = 0

    var startedCount: Int { lock.withLock { widths.count + currentCount } }
    var processedWidths: [Int] { lock.withLock { widths } }
    var maximumConcurrentCount: Int { lock.withLock { maximumCount } }

    func process(_ frame: EphemeralScreenFrame) {
        let width = frame.metadata.pixelWidth
        let shouldBlock = lock.withLock { () -> Bool in
            currentCount += 1
            maximumCount = max(maximumCount, currentCount)
            return widths.isEmpty
        }
        if shouldBlock { firstGate.wait() }
        lock.withLock {
            widths.append(width)
            currentCount -= 1
        }
    }

    func releaseFirst() {
        firstGate.signal()
    }
}

private struct AlwaysPermittedScreenOCRSafetyGate: ScreenOCRSafetyEvaluating {
    func permitsOCR() -> Bool { true }
}

private final class CancelBlockingScreenTextRecognizer: ScreenTextRecognizing, @unchecked Sendable {
    private let condition = NSCondition()
    private var active = false
    private var cancellations = 0

    var isRecognizing: Bool {
        condition.withLock { active }
    }

    var cancellationCount: Int {
        condition.withLock { cancellations }
    }

    func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition] {
        condition.lock()
        active = true
        condition.broadcast()
        while active { condition.wait() }
        condition.unlock()
        throw CancellationError()
    }

    func cancelPendingRecognition() {
        condition.withLock {
            guard active else { return }
            active = false
            cancellations += 1
            condition.broadcast()
        }
    }
}

private enum TestFrameError: Error {
    case authorizationDenied(ScreenCaptureStartAuthorizationFailure)
    case pixelBufferCreationFailed(CVReturn)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case timeout
}
