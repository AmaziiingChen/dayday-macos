@preconcurrency import CoreMedia
import DaydayCore
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let screenCaptureLogger = Logger(
    subsystem: "app.dayday.local",
    category: "screen-capture"
)

/// A per-display capture target derived from the volatile display reconciler.
public struct ScreenCaptureDisplayTarget: Sendable, Equatable {
    public let display: DisplayContext
    let runtimeDisplayID: UInt32

    public init(
        display: ReconciledDisplay,
        topologyRevision: DisplayTopologyRevision
    ) {
        self.display = DisplayContext(
            id: display.id,
            topologyRevision: topologyRevision.rawValue
        )
        self.runtimeDisplayID = display.descriptor.runtimeID
    }

    init(display: DisplayContext, runtimeDisplayID: UInt32) {
        self.display = display
        self.runtimeDisplayID = runtimeDisplayID
    }
}

public enum ScreenCaptureHardUnavailableReason: Sendable, Equatable {
    case authorizationRequired
    case sessionUnavailable
    case streamUnavailable
    case streamStopped
    case streamFailed
}

public enum ScreenCaptureAvailability: Sendable, Equatable {
    case idle
    case starting
    case available
    case hardUnavailable(ScreenCaptureHardUnavailableReason)
}

/// A sanitized objective state observation. Backend errors are intentionally not
/// surfaced as free-form strings because they may contain machine-specific context.
public struct ScreenCaptureAvailabilityFact: Sendable, Equatable {
    public let availability: ScreenCaptureAvailability
    public let observedAt: Date
    public let display: DisplayContext?

    public init(
        availability: ScreenCaptureAvailability,
        observedAt: Date,
        display: DisplayContext?
    ) {
        self.availability = availability
        self.observedAt = observedAt
        self.display = display
    }
}

/// A bounded, downscaled, credential-redacted derivative for immediate visual inference.
///
/// The value is intentionally non-Codable and contains no original-resolution sample or file URL.
/// Application composition normally consumes it transiently; the only durable route is the
/// bounded `ScreenVisionPendingEvidence` retry queue, which revalidates this compressed form and
/// removes it after a structured visual segment is archived.
public struct ObjectiveScreenVisionDerivative: Sendable, Equatable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyImage
        case oversizedImage(Int)
        case invalidDimensions
        case tooManyOCRLines(Int)
    }

    public let frame: ObjectiveScreenFrameMetadata
    public let encodedJPEG: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let redactedOCRLines: [RedactedOCRLine]

    public init(
        frame: ObjectiveScreenFrameMetadata,
        encodedJPEG: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        redactedOCRLines: [RedactedOCRLine]
    ) throws {
        guard !encodedJPEG.isEmpty else { throw ValidationError.emptyImage }
        guard encodedJPEG.count <= 2_000_000 else {
            throw ValidationError.oversizedImage(encodedJPEG.count)
        }
        guard pixelWidth > 0, pixelHeight > 0, max(pixelWidth, pixelHeight) <= 1_600 else {
            throw ValidationError.invalidDimensions
        }
        guard redactedOCRLines.count <= OCRArtifact.maximumLineCount else {
            throw ValidationError.tooManyOCRLines(redactedOCRLines.count)
        }
        self.frame = frame
        self.encodedJPEG = encodedJPEG
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.redactedOCRLines = redactedOCRLines
    }

    init?(
        frame: ObjectiveScreenFrameMetadata,
        prepared: PreparedScreenVisionDerivative,
        redactedOCRLines: [RedactedOCRLine]
    ) {
        try? self.init(
            frame: frame,
            encodedJPEG: prepared.encodedJPEG,
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight,
            redactedOCRLines: redactedOCRLines
        )
    }
}

public enum ScreenCaptureStreamOutput: Sendable, Equatable {
    case availability(ScreenCaptureAvailabilityFact)
    case frame(ObjectiveScreenFrameMetadata)
    case recognizedText(ObjectiveScreenTextObservation)
    case visionDerivative(ObjectiveScreenVisionDerivative)
}

enum ScreenCaptureBackendTermination: Sendable, Equatable {
    case stopped
    case failed
}

struct ScreenCaptureBackendCallbacks: Sendable {
    let frame: @Sendable (CapturedScreenSample) -> Void
    let terminated: @Sendable (ScreenCaptureBackendTermination) -> Void
}

protocol ScreenCaptureStreamBackend: Sendable {
    func start(
        sessionID: UInt64,
        runtimeDisplayID: UInt32,
        callbacks: ScreenCaptureBackendCallbacks
    ) async throws

    func stop(sessionID: UInt64) async
}

enum ScreenCaptureStartAuthorizationFailure: Sendable, Equatable {
    case productConsentRequired
    case screenRecordingAuthorizationRequired
}

enum ScreenCaptureConsentLeaseError: Error, Sendable, Equatable {
    case collectorMismatch
}

/// The live product-consent source captured by screen-start authorizations.
///
/// Application composition must update this value for every persisted
/// `screenUnderstanding` consent transition before attempting another start.
/// The concrete lease prevents production callers from substituting an
/// always-true validator while still letting an issued token observe a later
/// pause or disable decision.
final class ScreenCaptureConsentLease: @unchecked Sendable {
    private let lock = NSLock()
    private var consent: CollectorConsent

    init(consent: CollectorConsent) throws {
        guard consent.collector == .screenUnderstanding else {
            throw ScreenCaptureConsentLeaseError.collectorMismatch
        }
        self.consent = consent
    }

    func update(_ consent: CollectorConsent) throws {
        guard consent.collector == .screenUnderstanding else {
            throw ScreenCaptureConsentLeaseError.collectorMismatch
        }
        lock.withLock { self.consent = consent }
    }

    fileprivate var permitsCollection: Bool {
        lock.withLock { consent.permitsCollection }
    }
}

/// A single-use admission decision for one ScreenCaptureKit start attempt.
///
/// Callers cannot construct this value. The gate validates product consent and
/// Screen Recording authorization when issuing it, and the token revalidates
/// the non-prompting system preflight when consumed immediately before the
/// backend call. Reusing a token fails closed.
struct ScreenCaptureStartAuthorization: @unchecked Sendable {
    fileprivate final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let revalidate: @Sendable () -> Bool
        private var consumed = false

        init(revalidate: @escaping @Sendable () -> Bool) {
            self.revalidate = revalidate
        }

        func consume() -> Bool {
            let mayValidate = lock.withLock { () -> Bool in
                guard !consumed else { return false }
                consumed = true
                return true
            }
            return mayValidate && revalidateNow()
        }

        func revalidateNow() -> Bool {
            guard lock.withLock({ consumed }) else { return false }
            return revalidate()
        }
    }

    fileprivate let state: State

    fileprivate init(state: State) {
        self.state = state
    }

    fileprivate func consume() -> Bool {
        state.consume()
    }

    fileprivate func revalidateNow() -> Bool {
        state.revalidateNow()
    }
}

enum ScreenCaptureStartAuthorizationDecision: Sendable {
    case authorized(ScreenCaptureStartAuthorization)
    case denied(ScreenCaptureStartAuthorizationFailure)
}

/// The sole public factory for a ScreenCaptureKit start authorization.
/// Production callers cannot inject or replace the macOS preflight.
struct ScreenCaptureStartAuthorizationGate: Sendable {
    private let consentLease: ScreenCaptureConsentLease
    private let preflight: any CaptureAuthorizationPreflighting
    private let clock: @Sendable () -> Date

    init(consentLease: ScreenCaptureConsentLease) {
        self.init(
            consentLease: consentLease,
            preflight: MacOSCaptureAuthorizationPreflight(),
            clock: Date.init
        )
    }

    init(
        consentLease: ScreenCaptureConsentLease,
        preflight: any CaptureAuthorizationPreflighting,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.consentLease = consentLease
        self.preflight = preflight
        self.clock = clock
    }

    func authorizeStart() -> ScreenCaptureStartAuthorizationDecision {
        guard consentLease.permitsCollection else {
            return .denied(.productConsentRequired)
        }
        guard preflight.snapshot(at: clock()).screenRecording == .authorized else {
            return .denied(.screenRecordingAuthorizationRequired)
        }

        let preflight = self.preflight
        let clock = self.clock
        let consentLease = self.consentLease
        return .authorized(ScreenCaptureStartAuthorization(state: .init(
            revalidate: {
                consentLease.permitsCollection
                    && preflight.snapshot(at: clock()).screenRecording == .authorized
            }
        )))
    }
}

/// ScreenCaptureKit-backed, per-display frame stream.
///
/// The public boundary emits only sanitized state facts and objective frame
/// metadata. Raw samples remain in DaydayCapture's short-lived processing lane.
/// This type does not request TCC permission. Every start requires a single-use
/// authorization produced by ``ScreenCaptureStartAuthorizationGate`` after
/// product consent and a non-prompting system preflight both succeed.
public actor ScreenCaptureStream {
    public typealias OutputHandler = @Sendable (ScreenCaptureStreamOutput) -> Void

    private let backend: any ScreenCaptureStreamBackend
    private let framePump: EphemeralFramePump
    private let localOCRProcessor: LocalScreenOCRProcessor?
    private let clock: @Sendable () -> Date
    private let outputHandler: OutputHandler
    private var generation: UInt64 = 0
    private var revocationCount: UInt64 = 0
    private var activeTarget: ScreenCaptureDisplayTarget?
    private var availability: ScreenCaptureAvailability = .idle

    /// The stream-local invalidation epoch. Every stop, suspension, or backend
    /// termination bumps it; a capture taken before committing a start lets the
    /// stream detect that an external revocation landed before the start.
    var currentRevocationCount: UInt64 { revocationCount }

    public init(outputHandler: @escaping OutputHandler) {
        let ocrProcessor = LocalScreenOCRProcessor()
        self.backend = ScreenCaptureKitStreamBackend()
        self.framePump = EphemeralFramePump(processor: ocrProcessor.process)
        self.localOCRProcessor = ocrProcessor
        self.clock = Date.init
        self.outputHandler = outputHandler
    }

    init(
        backend: any ScreenCaptureStreamBackend,
        clock: @escaping @Sendable () -> Date,
        processor: @escaping EphemeralFramePump.Processor,
        outputHandler: @escaping OutputHandler
    ) {
        self.backend = backend
        self.framePump = EphemeralFramePump(processor: processor)
        self.localOCRProcessor = nil
        self.clock = clock
        self.outputHandler = outputHandler
    }

    init(
        backend: any ScreenCaptureStreamBackend,
        clock: @escaping @Sendable () -> Date,
        localOCRProcessor: LocalScreenOCRProcessor,
        outputHandler: @escaping OutputHandler
    ) {
        self.backend = backend
        self.framePump = EphemeralFramePump(processor: localOCRProcessor.process)
        self.localOCRProcessor = localOCRProcessor
        self.clock = clock
        self.outputHandler = outputHandler
    }

    /// Requests that the next active frame bypass the periodic OCR cadence. This is intentionally
    /// content-free: callers cannot attach a key, event, image, or timestamp, and the request
    /// still cannot bypass Capture's existing safety and generation gates.
    public func requestVisualAnchor() {
        guard activeTarget != nil, availability == .available else { return }
        localOCRProcessor?.requestImmediateProcessing()
    }

    /// Starts one display stream. Repeating the same request while starting or
    /// available is a no-op; a different display is an atomic stop/restart.
    ///
    /// `revokedAt` is the ``currentRevocationCount`` captured by the runtime
    /// just before committing this attempt. If a pause, disable, session loss,
    /// target clear, TCC revocation, or shutdown lands after that capture, the
    /// commit is abandoned before any backend session is created, so the stream
    /// can never start late or publish ``available`` after a revocation.
    func start(
        display target: ScreenCaptureDisplayTarget,
        authorization: ScreenCaptureStartAuthorization,
        revokedAt: UInt64
    ) async {
        guard authorization.consume() else {
            await failAuthorization(for: target)
            return
        }

        if activeTarget == target, availability == .starting || availability == .available {
            return
        }

        let previousGeneration = generation
        generation &+= 1
        let requestedGeneration = generation
        deactivateFrameProcessing()
        if activeTarget != nil || availability == .starting {
            await backend.stop(sessionID: previousGeneration)
        }

        guard revokedAt == revocationCount else {
            return
        }
        guard authorization.revalidateNow() else {
            generation &+= 1
            revocationCount &+= 1
            transition(to: .hardUnavailable(.authorizationRequired), display: target.display)
            return
        }

        let owner = WeakScreenCaptureStreamOwner(self)
        let localOCRProcessor = self.localOCRProcessor
        let callbacks = ScreenCaptureBackendCallbacks(
            frame: { [owner, framePump, clock] sample in
                guard let frame = EphemeralScreenFrame(
                    sample: sample,
                    display: target.display,
                    observedAt: clock()
                ) else {
                    return
                }
                framePump.submit(frame, generation: requestedGeneration) {
                    metadata, analysis, generation in
                    Task {
                        await owner.value?.processed(
                            metadata,
                            analysis: analysis,
                            generation: generation
                        )
                    }
                }
            },
            terminated: { [owner, framePump, localOCRProcessor] reason in
                framePump.deactivate()
                localOCRProcessor?.cancelPendingProcessing()
                Task {
                    await owner.value?.backendTerminated(
                        reason,
                        generation: requestedGeneration
                    )
                }
            }
        )

        activeTarget = target
        transition(to: .starting, display: target.display)

        do {
            try await backend.start(
                sessionID: requestedGeneration,
                runtimeDisplayID: target.runtimeDisplayID,
                callbacks: callbacks
            )
        } catch {
            guard generation == requestedGeneration else { return }
            deactivateFrameProcessing()
            activeTarget = nil
            await backend.stop(sessionID: requestedGeneration)
            transition(to: .hardUnavailable(.streamUnavailable), display: target.display)
            return
        }

        guard generation == requestedGeneration,
              revokedAt == revocationCount else {
            await backend.stop(sessionID: requestedGeneration)
            return
        }
        guard authorization.revalidateNow() else {
            generation &+= 1
            revocationCount &+= 1
            deactivateFrameProcessing()
            activeTarget = nil
            await backend.stop(sessionID: requestedGeneration)
            transition(to: .hardUnavailable(.authorizationRequired), display: target.display)
            return
        }
        framePump.activate(generation: requestedGeneration)
        transition(to: .available, display: target.display)
    }

    /// Stops capture without inventing an error fact. Repeated stops are no-ops.
    public func stop() async {
        // Even an idle stop is a semantic revocation boundary: it must invalidate
        // a start that captured the previous epoch but has not entered this actor.
        revocationCount &+= 1
        deactivateFrameProcessing()
        guard availability != .idle || activeTarget != nil else { return }
        let stoppedGeneration = generation
        generation &+= 1
        activeTarget = nil
        await backend.stop(sessionID: stoppedGeneration)
        transition(to: .idle, display: nil)
    }

    /// Generic composition hook for supported system/session/screen suppression.
    /// It does not assert or infer that the Mac is locked. Recovery is an
    /// authorized `start` with a newly issued single-use capability.
    public func suspendForUnavailableSession() async {
        // Repeated suppression still invalidates a recovery start queued from an
        // intervening available-session fact.
        revocationCount &+= 1
        deactivateFrameProcessing()
        if availability == .hardUnavailable(.sessionUnavailable), activeTarget == nil { return }
        let display = activeTarget?.display
        let stoppedGeneration = generation
        generation &+= 1
        activeTarget = nil
        await backend.stop(sessionID: stoppedGeneration)
        transition(to: .hardUnavailable(.sessionUnavailable), display: display)
    }

    /// Capture-owned runtime hook for consent or TCC loss. This never prompts
    /// and always invalidates the active generation before awaiting the backend.
    func suspendForAuthorizationLoss() async {
        revocationCount &+= 1
        deactivateFrameProcessing()
        if availability == .hardUnavailable(.authorizationRequired), activeTarget == nil {
            return
        }
        let display = activeTarget?.display
        let stoppedGeneration = generation
        generation &+= 1
        activeTarget = nil
        await backend.stop(sessionID: stoppedGeneration)
        transition(to: .hardUnavailable(.authorizationRequired), display: display)
    }

    private func failAuthorization(for target: ScreenCaptureDisplayTarget) async {
        let display = activeTarget?.display ?? target.display
        let hadBackendSession = activeTarget != nil
        let stoppedGeneration = generation
        generation &+= 1
        revocationCount &+= 1
        deactivateFrameProcessing()
        activeTarget = nil
        if hadBackendSession {
            await backend.stop(sessionID: stoppedGeneration)
        }
        transition(to: .hardUnavailable(.authorizationRequired), display: display)
    }

    private func processed(
        _ metadata: ObjectiveScreenFrameMetadata,
        analysis: EphemeralFrameAnalysis?,
        generation processedGeneration: UInt64
    ) {
        guard generation == processedGeneration,
              availability == .available,
              activeTarget?.display == metadata.display else {
            return
        }
        outputHandler(.frame(metadata))
        if let analysis {
            guard let observation = try? ObjectiveScreenTextObservation(
                frame: metadata,
                lines: analysis.lines,
                redactionApplied: analysis.redactionApplied
            ) else { return }
            outputHandler(.recognizedText(observation))
            if let derivative = analysis.visionDerivative,
               let output = ObjectiveScreenVisionDerivative(
                    frame: metadata,
                    prepared: derivative,
                    redactedOCRLines: analysis.lines
               ) {
                outputHandler(.visionDerivative(output))
            }
        }
    }

    private func backendTerminated(
        _ reason: ScreenCaptureBackendTermination,
        generation terminatedGeneration: UInt64
    ) async {
        guard generation == terminatedGeneration else { return }
        let display = activeTarget?.display
        let stoppedGeneration = generation
        generation &+= 1
        revocationCount &+= 1
        deactivateFrameProcessing()
        activeTarget = nil
        await backend.stop(sessionID: stoppedGeneration)
        switch reason {
        case .stopped:
            transition(to: .hardUnavailable(.streamStopped), display: display)
        case .failed:
            transition(to: .hardUnavailable(.streamFailed), display: display)
        }
    }

    private func transition(
        to newAvailability: ScreenCaptureAvailability,
        display: DisplayContext?
    ) {
        availability = newAvailability
        outputHandler(.availability(ScreenCaptureAvailabilityFact(
            availability: newAvailability,
            observedAt: clock(),
            display: display
        )))
    }

    private func deactivateFrameProcessing() {
        framePump.deactivate()
        localOCRProcessor?.cancelPendingProcessing()
    }
}

private actor ScreenCaptureKitStreamBackend: ScreenCaptureStreamBackend {
    private struct ActiveStream {
        let sessionID: UInt64
        let stream: SCStream
        let bridge: ScreenCaptureKitOutputBridge
    }

    private var desiredSessionID: UInt64?
    private var active: ActiveStream?

    func start(
        sessionID: UInt64,
        runtimeDisplayID: UInt32,
        callbacks: ScreenCaptureBackendCallbacks
    ) async throws {
        desiredSessionID = sessionID
        if let previous = active {
            active = nil
            await stop(previous)
        }
        try requireCurrent(sessionID)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        try requireCurrent(sessionID)
        guard let display = content.displays.first(where: { $0.displayID == runtimeDisplayID }) else {
            throw ScreenCaptureKitAdapterError.displayUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        // ScreenCaptureKit documents three as the minimum supported queue depth.
        // A value of one can let startCapture succeed while delivering no samples.
        configuration.queueDepth = 3
        // The local redaction and derivative encoder consumes a directly addressable BGRA
        // buffer. ScreenCaptureKit may otherwise choose another supported pixel format for the
        // active display, which still works for Vision OCR but cannot be safely copied by the
        // bounded derivative encoder.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
            ?? NSRunningApplication.current.bundleIdentifier
        let ownApplication = ownBundleIdentifier.flatMap { bundleIdentifier in
            content.applications.first { $0.bundleIdentifier == bundleIdentifier }
        }
        let ownWindows = ownBundleIdentifier.map { bundleIdentifier in
            content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleIdentifier
            }
        } ?? []
        let filter: SCContentFilter
        if let ownApplication {
            // Never let Dayday observe its own journal, settings, or diagnostics surfaces. This is
            // both a privacy boundary and a resource boundary: a visible journal must not trigger
            // OCR work in the same process that is handling the user's input method.
            filter = SCContentFilter(
                display: display,
                excludingApplications: [ownApplication],
                exceptingWindows: []
            )
        } else {
            // Some shareable-content snapshots omit the application row during a visibility
            // transition while still reporting its windows. Keep the window-level fallback so
            // that transition cannot momentarily admit Dayday pixels.
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }
        let bridge = ScreenCaptureKitOutputBridge(callbacks: callbacks)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
        try stream.addStreamOutput(
            bridge,
            type: .screen,
            sampleHandlerQueue: bridge.outputQueue
        )

        do {
            try requireCurrent(sessionID)
        } catch {
            try? stream.removeStreamOutput(bridge, type: .screen)
            throw error
        }

        active = ActiveStream(sessionID: sessionID, stream: stream, bridge: bridge)
        do {
            try await stream.startCapture()
            try requireCurrent(sessionID)
        } catch {
            if active?.sessionID == sessionID {
                active = nil
            }
            await stop(ActiveStream(sessionID: sessionID, stream: stream, bridge: bridge))
            throw error
        }
    }

    func stop(sessionID: UInt64) async {
        if desiredSessionID == sessionID {
            desiredSessionID = nil
        }
        guard let current = active, current.sessionID == sessionID else { return }
        active = nil
        await stop(current)
    }

    private func requireCurrent(_ sessionID: UInt64) throws {
        guard desiredSessionID == sessionID else {
            throw ScreenCaptureKitAdapterError.superseded
        }
    }

    private func stop(_ current: ActiveStream) async {
        try? await current.stream.stopCapture()
        try? current.stream.removeStreamOutput(current.bridge, type: .screen)
    }
}

private final class WeakScreenCaptureStreamOwner: @unchecked Sendable {
    weak var value: ScreenCaptureStream?

    init(_ value: ScreenCaptureStream) {
        self.value = value
    }
}

private enum ScreenCaptureKitAdapterError: Error {
    case displayUnavailable
    case superseded
}

private final class ScreenCaptureKitOutputBridge: NSObject, @unchecked Sendable,
    SCStreamDelegate, SCStreamOutput {
    let outputQueue = DispatchQueue(
        label: "com.dayday.capture.screencapturekit-output",
        qos: .utility
    )

    private let lock = NSLock()
    private var callbacks: ScreenCaptureBackendCallbacks?
    private var didLogFirstSample = false

    init(callbacks: ScreenCaptureBackendCallbacks) {
        self.callbacks = callbacks
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        let status = Self.status(of: sampleBuffer)
        logFirstSample(status: status)
        switch status {
        case .complete:
            callbackSnapshot()?.frame(CapturedScreenSample(sampleBuffer: sampleBuffer))
        case .stopped:
            terminate(.stopped)
        case .idle, .blank, .suspended, .started:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        terminate(.failed)
    }

    private func callbackSnapshot() -> ScreenCaptureBackendCallbacks? {
        lock.withLock { callbacks }
    }

    private func logFirstSample(status: SCFrameStatus) {
        let shouldLog = lock.withLock { () -> Bool in
            guard !didLogFirstSample else { return false }
            didLogFirstSample = true
            return true
        }
        guard shouldLog else { return }
        screenCaptureLogger.notice(
            "Received first ScreenCaptureKit sample with status \(status.rawValue)"
        )
    }

    private func terminate(_ reason: ScreenCaptureBackendTermination) {
        let callback = lock.withLock { () -> ScreenCaptureBackendCallbacks? in
            defer { callbacks = nil }
            return callbacks
        }
        callback?.terminated(reason)
    }

    private static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            return .blank
        }
        return status
    }
}
