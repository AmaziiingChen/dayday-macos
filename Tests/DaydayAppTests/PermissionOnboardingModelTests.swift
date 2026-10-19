@testable import DaydayApp
import DaydayCapture
import DaydayCore
import Foundation
import Testing

@Suite("Permission onboarding model", .serialized)
@MainActor
struct PermissionOnboardingModelTests {
    @Test("Construction and nonprompting refresh never invoke the TCC requester")
    func launchAndRefreshArePromptInert() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil)
        )
        let statusProvider = AuthorizationStatusProbe(defaultState: .notDetermined)
        let recovery = RecoveryOpenerProbe()
        let model = PermissionOnboardingModel(
            requester: requester,
            statusProvider: statusProvider,
            recoveryOpener: recovery
        )

        #expect(model.collectorStates.count == CollectorKind.allCases.count)
        #expect(model.collectorStates.allSatisfy { $0.consent == .unconfirmed })
        #expect(await requester.callCount == 0)
        #expect(await statusProvider.callCount == 0)
        #expect(recovery.opened.isEmpty)

        model.refreshSystemStatuses()
        model.refreshSystemStatuses()

        let finished = await eventually { @MainActor in
            !model.isRefreshing
        }
        #expect(finished)
        #expect(await requester.callCount == 0)
        #expect(await statusProvider.callCount == PermissionOnboardingModel.collectionStatusPermissions.count)
        #expect(recovery.opened.isEmpty)
    }

    @Test("Every collector keeps independent product consent and pause state")
    func collectorConsentIsIndependent() {
        let model = PermissionOnboardingModel()

        model.enable(.screenUnderstanding)
        #expect(model.state(for: .screenUnderstanding).consent == .enabled)
        #expect(model.state(for: .applicationWindowContext).consent == .unconfirmed)

        model.enable(.weather)
        model.pause(.screenUnderstanding)
        #expect(model.state(for: .screenUnderstanding).consent == .paused)
        #expect(model.state(for: .weather).consent == .enabled)
        #expect(model.state(for: .keyboardAggregates).consent == .unconfirmed)

        model.disable(.weather)
        #expect(model.state(for: .weather).consent == .disabled)
        #expect(model.state(for: .screenUnderstanding).consent == .paused)
    }

    @Test("First-run progress counts only collectors that still need a decision")
    func unconfirmedCollectorCountTracksExplicitDecisions() {
        let model = PermissionOnboardingModel()

        #expect(model.unconfirmedCollectorCount == PermissionOnboardingModel.collectionStatusCollectors.count)

        model.enable(.weather)
        #expect(model.unconfirmedCollectorCount == PermissionOnboardingModel.collectionStatusCollectors.count - 1)

        model.disable(.calendar)
        #expect(model.unconfirmedCollectorCount == PermissionOnboardingModel.collectionStatusCollectors.count - 1)

        model.pause(.weather)
        #expect(model.unconfirmedCollectorCount == PermissionOnboardingModel.collectionStatusCollectors.count - 1)
    }

    @Test("Capture bridge receives only persisted screen consent changes")
    func captureBridgeIgnoresOtherCollectors() {
        let model = PermissionOnboardingModel()
        var received: [CollectorConsent] = []
        model.setScreenCaptureConsentChangeHandler { received.append($0) }

        #expect(received.map(\.status) == [.unconfirmed])
        model.enable(.weather)
        model.pause(.weather)
        #expect(received.map(\.status) == [.unconfirmed])

        model.enable(.screenUnderstanding)
        model.pause(.screenUnderstanding)
        #expect(received.map(\.status) == [.unconfirmed, .enabled, .paused])
        #expect(received.allSatisfy { $0.collector == .screenUnderstanding })
    }

    @Test("Application-window confirmation is delegated to the durable control path")
    func applicationWindowControlUsesProductionHandler() async {
        let model = PermissionOnboardingModel()
        var received: [CollectorConsentAction] = []
        model.setApplicationWindowControlHandler { action in
            received.append(action)
            let updated = try CollectorConsentStateMachine.transition(
                action, from: CollectorConsent(collector: .applicationWindowContext)
            )
            return PersistedCollectorConsent(
                consent: updated, lastAction: action, revision: 1
            )
        }

        model.enable(.applicationWindowContext)

        #expect(await eventually { @MainActor in
            model.state(for: .applicationWindowContext).consent == .enabled
        })
        #expect(received.count == 1)
        guard case let .enable(confirmation) = received[0] else {
            Issue.record("Expected an enable action")
            return
        }
        #expect(confirmation.collector == .applicationWindowContext)
    }

    @Test("Settings-only collectors use the durable control path and restore without writing")
    func settingsOnlyCollectorsUseDurableControlAndRestore() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil)
        )
        let model = PermissionOnboardingModel(requester: requester)
        var received: [CollectorConsentAction] = []
        model.setPersistedCollectorControlHandler { collector, action in
            received.append(action)
            let updated = try CollectorConsentStateMachine.transition(
                action, from: CollectorConsent(collector: collector)
            )
            return PersistedCollectorConsent(consent: updated, lastAction: action, revision: 1)
        }

        model.enable(.weather)

        #expect(await eventually { @MainActor in
            model.state(for: .weather).consent == .enabled
        })
        #expect(received.count == 1)
        guard case let .enable(confirmation) = received[0] else {
            Issue.record("Expected an enable action")
            return
        }
        #expect(confirmation.collector == .weather)

        let restored = try! CollectorConsentStateMachine.transition(
            .enable(try! UserConsentConfirmation(
                collector: .calendar,
                confirmedAt: .now,
                disclosureVersion: PermissionOnboardingModel.disclosureVersion
            )),
            from: CollectorConsent(collector: .calendar)
        )
        model.applyPersistedConsent(
            PersistedCollectorConsent(consent: restored, lastAction: nil, revision: 1)
        )
        #expect(model.state(for: .calendar).consent == .enabled)
        #expect(received.count == 1)
        #expect(await requester.callCount == 0)
    }

    @Test("A complete restored profile does not present first-run onboarding again")
    func completeRestoredProfileDismissesFirstRun() {
        let model = PermissionOnboardingModel()

        #expect(model.isFirstRunPresented)
        for (index, collector) in CollectorKind.allCases.enumerated() {
            model.applyPersistedConsent(
                PersistedCollectorConsent(
                    consent: enabledConsent(for: collector),
                    lastAction: nil,
                    revision: UInt64(index + 1)
                )
            )
            if index < CollectorKind.allCases.count - 1 {
                #expect(model.isFirstRunPresented)
            }
        }

        #expect(!model.isFirstRunPresented)
        #expect(model.collectorStates.allSatisfy { $0.consent == .enabled })
    }

    @Test("A denial exposes only the canonical recovery destination")
    func denialProvidesRecoveryAction() async {
        let descriptor = SystemSettingsDeepLinkDescriptor(permission: .accessibility)
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .denied, recovery: descriptor)
        )
        let recovery = RecoveryOpenerProbe()
        let repository = InMemoryCollectorConsentRepository(values: [
            .applicationWindowContext: enabledConsent(for: .applicationWindowContext)
        ])
        let model = PermissionOnboardingModel(
            repository: repository,
            requester: requester,
            recoveryOpener: recovery
        )

        await model.requestSystemPermission(for: .applicationWindowContext)

        let state = model.state(for: .applicationWindowContext)
        #expect(state.authorization == .denied)
        #expect(state.recovery == descriptor)
        #expect(await requester.callCount == 1)

        model.openRecovery(for: .applicationWindowContext)
        #expect(recovery.opened == [descriptor])
    }

    @Test("An unresolved synchronous prompt never publishes a denial")
    func unresolvedPromptRemainsUnknownUntilPreflightAuthorizes() async {
        let descriptor = SystemSettingsDeepLinkDescriptor(permission: .screenRecording)
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .unknown, recovery: descriptor)
        )
        let statusProvider = SuspendedAuthorizationStatusProbe(
            state: .authorized,
            suspendedPermission: .screenRecording
        )
        let repository = InMemoryCollectorConsentRepository(values: [
            .screenUnderstanding: enabledConsent(for: .screenUnderstanding)
        ])
        let model = PermissionOnboardingModel(
            repository: repository,
            requester: requester,
            statusProvider: statusProvider,
            promptObservationDelay: .zero
        )

        let request = Task { @MainActor in
            await model.requestSystemPermission(for: .screenUnderstanding)
        }
        #expect(await eventually { @MainActor in
            model.state(for: .screenUnderstanding).recovery == descriptor
        })
        #expect(await statusProvider.callCount == 1)

        let unresolved = model.state(for: .screenUnderstanding)
        #expect(unresolved.authorization == .unknown)
        #expect(unresolved.message?.contains("等待") == true)
        #expect(unresolved.message?.contains("拒绝") == false)
        #expect(unresolved.recovery == descriptor)

        await statusProvider.release()
        await request.value
        #expect(model.state(for: .screenUnderstanding).authorization == .authorized)
    }

    @Test("Repeated request clicks coalesce while one collector request is in flight")
    func repeatedRequestsCoalesce() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil),
            suspends: true
        )
        let repository = InMemoryCollectorConsentRepository(values: [
            .screenUnderstanding: enabledConsent(for: .screenUnderstanding)
        ])
        let model = PermissionOnboardingModel(
            repository: repository,
            requester: requester
        )

        let first = Task { @MainActor in
            await model.requestSystemPermission(for: .screenUnderstanding)
        }
        let started = await eventually {
            await requester.callCount == 1
        }
        #expect(started)
        #expect(model.state(for: .screenUnderstanding).isRequesting)

        await model.requestSystemPermission(for: .screenUnderstanding)
        await model.requestSystemPermission(for: .screenUnderstanding)
        #expect(await requester.callCount == 1)

        await requester.release()
        await first.value
        #expect(!model.state(for: .screenUnderstanding).isRequesting)
        #expect(model.state(for: .screenUnderstanding).authorization == .authorized)
    }

    @Test("A stale status refresh cannot overwrite a newer explicit request result")
    func staleRefreshCannotDowngradeExplicitResult() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil),
            suspends: true
        )
        let statusProvider = SuspendedAuthorizationStatusProbe(
            state: .denied,
            suspendedPermission: .screenRecording
        )
        let repository = InMemoryCollectorConsentRepository(values: [
            .screenUnderstanding: enabledConsent(for: .screenUnderstanding)
        ])
        let model = PermissionOnboardingModel(
            repository: repository,
            requester: requester,
            statusProvider: statusProvider
        )

        model.refreshSystemStatuses()
        #expect(await eventually { await statusProvider.callCount >= 1 })

        let request = Task { @MainActor in
            await model.requestSystemPermission(for: .screenUnderstanding)
        }
        #expect(await eventually { await requester.callCount == 1 })
        await requester.release()
        await request.value
        #expect(model.state(for: .screenUnderstanding).authorization == .authorized)

        await statusProvider.release()
        #expect(await eventually { @MainActor in !model.isRefreshing })
        #expect(model.state(for: .screenUnderstanding).authorization == .authorized)
    }

    @Test("Collectors sharing one TCC permission expose one consistent in-flight state")
    func sharedPermissionRequestStateIsConsistent() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil),
            suspends: true
        )
        let repository = InMemoryCollectorConsentRepository(values: [
            .keyboardAggregates: enabledConsent(for: .keyboardAggregates),
            .pointerAggregates: enabledConsent(for: .pointerAggregates),
        ])
        let model = PermissionOnboardingModel(repository: repository, requester: requester)

        let keyboardRequest = Task { @MainActor in
            await model.requestSystemPermission(for: .keyboardAggregates)
        }
        #expect(await eventually { await requester.callCount == 1 })
        #expect(model.state(for: .keyboardAggregates).isRequesting)
        #expect(model.state(for: .pointerAggregates).isRequesting)

        await model.requestSystemPermission(for: .pointerAggregates)
        #expect(await requester.callCount == 1)

        await requester.release()
        await keyboardRequest.value
        #expect(!model.state(for: .keyboardAggregates).isRequesting)
        #expect(!model.state(for: .pointerAggregates).isRequesting)
    }

    @Test("Pause and disable remain authoritative while a permission request is suspended")
    func consentChangeDuringRequestNeverReenablesCollection() async {
        for expectedStatus in [CollectorConsentStatus.paused, .disabled] {
            let requester = PermissionRequesterProbe(
                outcome: .completed(authorization: .authorized, recovery: nil),
                suspends: true
            )
            let repository = InMemoryCollectorConsentRepository(values: [
                .screenUnderstanding: enabledConsent(for: .screenUnderstanding)
            ])
            let model = PermissionOnboardingModel(repository: repository, requester: requester)
            let request = Task { @MainActor in
                await model.requestSystemPermission(for: .screenUnderstanding)
            }
            #expect(await eventually { await requester.callCount == 1 })

            if expectedStatus == .paused {
                model.pause(.screenUnderstanding)
            } else {
                model.disable(.screenUnderstanding)
            }
            #expect(model.state(for: .screenUnderstanding).consent == expectedStatus)

            await requester.release()
            await request.value
            let final = model.state(for: .screenUnderstanding)
            #expect(final.consent == expectedStatus)
            #expect(await requester.callCount == 1)
            #expect(final.message?.contains("仍保持") == true)
        }
    }

    @Test("Collectors without TCC requirements never call the permission requester")
    func permissionlessCollectorSkipsRequester() async {
        let requester = PermissionRequesterProbe(
            outcome: .completed(authorization: .authorized, recovery: nil)
        )
        let repository = InMemoryCollectorConsentRepository(values: [
            .weather: enabledConsent(for: .weather)
        ])
        let model = PermissionOnboardingModel(
            repository: repository,
            requester: requester
        )

        await model.requestSystemPermission(for: .weather)

        #expect(await requester.callCount == 0)
        #expect(model.state(for: .weather).authorization == .notRequired)
    }

    @Test("Main window and menu bar receive the identical onboarding model")
    func compositionSharesModelIdentity() {
        let permissionModel = PermissionOnboardingModel()
        let composition = DaydayAppComposition(
            runtime: AppRuntimeModel(
                provider: PreviewAppRuntimeSnapshotProvider(value: .previewAuthorized)
            ),
            permissionOnboarding: permissionModel,
            shouldBootstrapProduction: false
        )

        #expect(composition.mainWindowPermissionModel === permissionModel)
        #expect(composition.menuBarPermissionModel === permissionModel)
        #expect(composition.mainWindowPermissionModel === composition.menuBarPermissionModel)
    }

    @Test("Foreground Dayday publishes no screen-capture targets")
    func foregroundCapturePolicySuppressesAllDisplays() {
        #expect(
            ScreenCaptureForegroundPolicy.isHostInteractionActive(
                applicationIsActive: false,
                hasKeyWindow: true
            )
        )
        #expect(
            ScreenCaptureForegroundPolicy.isHostInteractionActive(
                applicationIsActive: true,
                hasKeyWindow: false
            )
        )
        #expect(
            !ScreenCaptureForegroundPolicy.isHostInteractionActive(
                applicationIsActive: false,
                hasKeyWindow: false
            )
        )
        #expect(
            ScreenCaptureForegroundPolicy.effectiveTargets(
                [1, 2],
                isHostApplicationActive: true
            ).isEmpty
        )
        #expect(
            ScreenCaptureForegroundPolicy.effectiveTargets(
                [1, 2],
                isHostApplicationActive: false
            ) == [1, 2]
        )
        #expect(
            !ScreenCaptureForegroundPolicy.shouldRefreshDisplayTargets(
                isHostApplicationActive: true
            )
        )
        #expect(
            ScreenCaptureForegroundPolicy.shouldRefreshDisplayTargets(
                isHostApplicationActive: false
            )
        )
    }

    @Test("Production composition forwards consent and objective session availability")
    func compositionWiresCaptureRuntimeWithoutPromptSurface() async {
        let permissionModel = PermissionOnboardingModel()
        let captureRuntime = ScreenCaptureConsentRuntime(outputHandler: { _ in })
        let lifecycle = AppCaptureLifecycleSource(
            availability: SystemLifecycleAvailability(
                isUserSessionActive: false,
                areScreensAwake: false
            )
        )
        let composition = DaydayAppComposition(
            permissionOnboarding: permissionModel,
            screenCaptureRuntime: captureRuntime,
            lifecycleNotificationSource: lifecycle,
            shouldBootstrapProduction: false
        )

        #expect(await eventually {
            let snapshot = await captureRuntime.snapshot()
            return snapshot.consentStatus == .unconfirmed && !snapshot.isSessionAvailable
        })

        permissionModel.enable(.weather)
        #expect((await captureRuntime.snapshot()).consentStatus == .unconfirmed)
        permissionModel.enable(.screenUnderstanding)
        permissionModel.pause(.screenUnderstanding)
        #expect(await eventually {
            await captureRuntime.snapshot().consentStatus == .paused
        })
        permissionModel.resume(.screenUnderstanding)

        lifecycle.send(.userSessionDidBecomeActive)
        lifecycle.send(.screensDidWake)
        #expect(await eventually {
            let snapshot = await captureRuntime.snapshot()
            return snapshot.consentStatus == .enabled && snapshot.isSessionAvailable
        })
        #expect(composition.mainWindowPermissionModel === permissionModel)
        await captureRuntime.shutdown()
    }
}

@MainActor
private final class AppCaptureLifecycleSource: SystemLifecycleNotificationSource {
    private let availability: SystemLifecycleAvailability
    private var handler: (@MainActor @Sendable (SystemLifecycleEvent) -> Void)?

    init(availability: SystemLifecycleAvailability) {
        self.availability = availability
    }

    func currentAvailability() -> SystemLifecycleAvailability {
        availability
    }

    func observe(
        _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
    ) -> any SystemLifecycleObservation {
        self.handler = handler
        return AppCaptureLifecycleObservation { [weak self] in
            self?.handler = nil
        }
    }

    func send(_ event: SystemLifecycleEvent) {
        handler?(event)
    }
}

@MainActor
private final class AppCaptureLifecycleObservation: SystemLifecycleObservation {
    private var cancellation: (@MainActor () -> Void)?

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

private actor PermissionRequesterProbe: PermissionRequesting {
    private let outcome: PermissionRequestOutcome
    private let suspends: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(outcome: PermissionRequestOutcome, suspends: Bool = false) {
        self.outcome = outcome
        self.suspends = suspends
    }

    func requestPermission(
        for consent: CollectorConsent,
        trigger: PermissionRequestTrigger
    ) async -> PermissionRequestOutcome {
        callCount += 1
        if suspends {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return outcome
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AuthorizationStatusProbe: PermissionAuthorizationStatusProviding {
    private let defaultState: AuthorizationState
    private(set) var callCount = 0

    init(defaultState: AuthorizationState) {
        self.defaultState = defaultState
    }

    func authorizationStatus(for permission: PlatformPermissionKind) -> AuthorizationState {
        callCount += 1
        return defaultState
    }
}

private actor SuspendedAuthorizationStatusProbe: PermissionAuthorizationStatusProviding {
    private let state: AuthorizationState
    private let suspendedPermission: PlatformPermissionKind
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSuspend = false
    private(set) var callCount = 0

    init(state: AuthorizationState, suspendedPermission: PlatformPermissionKind) {
        self.state = state
        self.suspendedPermission = suspendedPermission
    }

    func authorizationStatus(for permission: PlatformPermissionKind) async -> AuthorizationState {
        callCount += 1
        if permission == suspendedPermission, !didSuspend {
            didSuspend = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return state
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecoveryOpenerProbe: PermissionRecoveryOpening {
    private(set) var opened: [SystemSettingsDeepLinkDescriptor] = []

    func open(_ descriptor: SystemSettingsDeepLinkDescriptor) -> Bool {
        opened.append(descriptor)
        return true
    }
}

@MainActor
private func enabledConsent(for collector: CollectorKind) -> CollectorConsent {
    let confirmation = try! UserConsentConfirmation(
        collector: collector,
        confirmedAt: Date(timeIntervalSinceReferenceDate: 100),
        disclosureVersion: PermissionOnboardingModel.disclosureVersion
    )
    return try! CollectorConsentStateMachine.transition(
        .enable(confirmation),
        from: CollectorConsent(collector: collector)
    )
}

private func eventually(
    attempts: Int = 500,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
