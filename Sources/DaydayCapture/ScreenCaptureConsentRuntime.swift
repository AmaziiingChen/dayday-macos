import DaydayCore
import Foundation

public enum ScreenCaptureConsentRuntimeError: Error, Equatable, Sendable {
    case collectorMismatch
}

/// Objective, non-prompting state exposed by the Capture-owned screen runtime.
public struct ScreenCaptureConsentRuntimeSnapshot: Equatable, Sendable {
    public let consentStatus: CollectorConsentStatus
    public let screenRecordingAuthorization: CaptureAuthorizationPreflightState
    public let isSessionAvailable: Bool
    public let hasDisplayTarget: Bool

    public init(
        consentStatus: CollectorConsentStatus,
        screenRecordingAuthorization: CaptureAuthorizationPreflightState,
        isSessionAvailable: Bool,
        hasDisplayTarget: Bool
    ) {
        self.consentStatus = consentStatus
        self.screenRecordingAuthorization = screenRecordingAuthorization
        self.isSessionAvailable = isSessionAvailable
        self.hasDisplayTarget = hasDisplayTarget
    }
}

/// The sole production owner of screen-understanding consent, start leases,
/// single-use start capabilities, and ScreenCaptureKit stream reconciliation.
///
/// This boundary never requests a macOS permission. App composition may only
/// publish already-persisted product consent and objective display/session
/// facts. Capture performs non-prompting authorization preflight itself.
public actor ScreenCaptureConsentRuntime {
    private let consentLease: ScreenCaptureConsentLease
    private let authorizationGate: ScreenCaptureStartAuthorizationGate
    private let preflight: any CaptureAuthorizationPreflighting
    private let stream: ScreenCaptureStream
    private let clock: @Sendable () -> Date
    private let authorizationMonitorInterval: Duration

    private var consent: CollectorConsent
    private var target: ScreenCaptureDisplayTarget?
    private var isSessionAvailable = false
    private var lastAuthorization: CaptureAuthorizationPreflightState
    private var revision: UInt64 = 0
    private var isShutdown = false
    private var monitorID = UUID()
    private var monitorTask: Task<Void, Never>?

    public init(outputHandler: @escaping ScreenCaptureStream.OutputHandler) {
        let consent = CollectorConsent(collector: .screenUnderstanding)
        let lease = try! ScreenCaptureConsentLease(consent: consent)
        let preflight = MacOSCaptureAuthorizationPreflight()
        self.consent = consent
        self.consentLease = lease
        self.preflight = preflight
        self.authorizationGate = ScreenCaptureStartAuthorizationGate(
            consentLease: lease,
            preflight: preflight
        )
        self.stream = ScreenCaptureStream(outputHandler: outputHandler)
        self.clock = Date.init
        self.authorizationMonitorInterval = .seconds(1)
        self.lastAuthorization = preflight.snapshot(at: Date()).screenRecording
    }

    init(
        initialConsent: CollectorConsent = CollectorConsent(
            collector: .screenUnderstanding
        ),
        preflight: any CaptureAuthorizationPreflighting,
        stream: ScreenCaptureStream,
        clock: @escaping @Sendable () -> Date = Date.init,
        authorizationMonitorInterval: Duration = .seconds(1)
    ) throws {
        guard initialConsent.collector == .screenUnderstanding else {
            throw ScreenCaptureConsentRuntimeError.collectorMismatch
        }
        let lease = try ScreenCaptureConsentLease(consent: initialConsent)
        self.consent = initialConsent
        self.consentLease = lease
        self.preflight = preflight
        self.authorizationGate = ScreenCaptureStartAuthorizationGate(
            consentLease: lease,
            preflight: preflight,
            clock: clock
        )
        self.stream = stream
        self.clock = clock
        self.authorizationMonitorInterval = authorizationMonitorInterval
        self.lastAuthorization = preflight.snapshot(at: clock()).screenRecording
    }

    deinit {
        monitorTask?.cancel()
    }

    /// Publishes a product-consent value only after App has durably accepted it.
    /// Pause, disable, and unconfirmed values invalidate the lease and stop now.
    public func updateConsent(_ updated: CollectorConsent) async throws {
        guard updated.collector == .screenUnderstanding else {
            throw ScreenCaptureConsentRuntimeError.collectorMismatch
        }
        guard !isShutdown else { return }

        consent = updated
        try consentLease.update(updated)
        revision &+= 1
        let requestedRevision = revision

        if !updated.permitsCollection {
            updateMonitor()
            await stream.suspendForAuthorizationLoss()
            return
        }
        updateMonitor()
        scheduleReconcile(expectedRevision: requestedRevision)
    }

    /// Replaces the volatile display target. Clearing it immediately stops the
    /// active stream; a new target starts only after all gates are still valid.
    public func setDisplayTarget(_ updated: ScreenCaptureDisplayTarget?) async {
        guard !isShutdown else { return }
        target = updated
        revision &+= 1
        let requestedRevision = revision

        if updated == nil {
            updateMonitor()
            await stream.stop()
            return
        }
        updateMonitor()
        scheduleReconcile(expectedRevision: requestedRevision)
    }

    /// Applies an objective graphical-session fact. Unavailability always cuts
    /// the stream; recovery requires a fresh Capture-owned single-use token.
    public func setSessionAvailable(_ available: Bool) async {
        guard !isShutdown else { return }
        guard isSessionAvailable != available else { return }
        isSessionAvailable = available
        revision &+= 1
        let requestedRevision = revision

        if !available {
            updateMonitor()
            await stream.suspendForUnavailableSession()
            return
        }
        updateMonitor()
        scheduleReconcile(expectedRevision: requestedRevision)
    }

    /// Immediately re-runs the non-prompting preflight. This is safe on launch,
    /// foregrounding, or after returning from System Settings.
    public func refreshAuthorization() async {
        guard !isShutdown else { return }
        revision &+= 1
        let requestedRevision = revision
        scheduleReconcile(expectedRevision: requestedRevision)
    }

    public func snapshot() -> ScreenCaptureConsentRuntimeSnapshot {
        ScreenCaptureConsentRuntimeSnapshot(
            consentStatus: consent.status,
            screenRecordingAuthorization: lastAuthorization,
            isSessionAvailable: isSessionAvailable,
            hasDisplayTarget: target != nil
        )
    }

    /// Fans a content-free observation anchor into the active stream. A request made while
    /// collection is unavailable is intentionally dropped rather than retained for a later
    /// session, so it cannot cross a pause, lock, or authorization boundary.
    public func requestVisualAnchor() async {
        guard !isShutdown, consent.permitsCollection, isSessionAvailable, target != nil else {
            return
        }
        await stream.requestVisualAnchor()
    }

    /// Idempotent application teardown. It cancels monitoring before stopping
    /// so no late poll can acquire a fresh start capability.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        revision &+= 1
        target = nil
        isSessionAvailable = false
        cancelMonitor()
        await stream.stop()
    }

    private var shouldMonitor: Bool {
        !isShutdown && consent.permitsCollection && target != nil && isSessionAvailable
    }

    /// Positive reconciliation may wait in ScreenCaptureKit. Launching it as a
    /// child operation keeps the actor available for consent, lifecycle, and
    /// shutdown revocations, whose revision changes make this work stale.
    private func scheduleReconcile(expectedRevision: UInt64) {
        Task { [weak self] in
            await self?.reconcile(expectedRevision: expectedRevision)
        }
    }

    private func reconcile(expectedRevision: UInt64) async {
        guard expectedRevision == revision, shouldMonitor, let target else { return }

        let authorization = preflight.snapshot(at: clock()).screenRecording
        lastAuthorization = authorization
        guard expectedRevision == revision else { return }
        guard authorization == .authorized else {
            await stream.suspendForAuthorizationLoss()
            return
        }

        switch authorizationGate.authorizeStart() {
        case let .authorized(startAuthorization):
            let revokedAt = await stream.currentRevocationCount
            guard expectedRevision == revision, shouldMonitor else { return }
            await stream.start(
                display: target,
                authorization: startAuthorization,
                revokedAt: revokedAt
            )
        case .denied:
            await stream.suspendForAuthorizationLoss()
        }
    }

    private func updateMonitor() {
        guard shouldMonitor else {
            cancelMonitor()
            return
        }
        guard monitorTask == nil else { return }

        let id = UUID()
        monitorID = id
        let interval = authorizationMonitorInterval
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      await self?.authorizationMonitorFired(id: id) == true else {
                    return
                }
            }
        }
    }

    private func authorizationMonitorFired(id: UUID) async -> Bool {
        guard id == monitorID, shouldMonitor else { return false }
        revision &+= 1
        await reconcile(expectedRevision: revision)
        return id == monitorID && shouldMonitor
    }

    private func cancelMonitor() {
        monitorID = UUID()
        monitorTask?.cancel()
        monitorTask = nil
    }
}
