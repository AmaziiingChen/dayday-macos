@preconcurrency import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import DaydayCapture
import DaydayCore
import EventKit
import Foundation

protocol CollectorConsentRepository: AnyObject {
    func consent(for collector: CollectorKind) -> CollectorConsent
    func save(_ consent: CollectorConsent) throws
}

final class InMemoryCollectorConsentRepository: CollectorConsentRepository {
    private var values: [CollectorKind: CollectorConsent]

    init(values: [CollectorKind: CollectorConsent] = [:]) {
        self.values = values
    }

    func consent(for collector: CollectorKind) -> CollectorConsent {
        values[collector] ?? CollectorConsent(collector: collector)
    }

    func save(_ consent: CollectorConsent) throws {
        values[consent.collector] = consent
    }
}

protocol PermissionAuthorizationStatusProviding: Sendable {
    func authorizationStatus(for permission: PlatformPermissionKind) async -> AuthorizationState
}

struct LivePermissionAuthorizationStatusProvider: PermissionAuthorizationStatusProviding {
    func authorizationStatus(for permission: PlatformPermissionKind) async -> AuthorizationState {
        switch permission {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .authorized : .unknown
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .unknown
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .authorized : .unknown
        case .calendar:
            return Self.authorizationState(
                for: EKEventStore.authorizationStatus(for: .event)
            )
        case .reminders:
            return Self.authorizationState(
                for: EKEventStore.authorizationStatus(for: .reminder)
            )
        }
    }

    private static func authorizationState(
        for status: EKAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .fullAccess, .authorized:
            return .authorized
        case .writeOnly:
            return .insufficientAccess
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }
}

@MainActor
protocol PermissionRecoveryOpening: AnyObject {
    @discardableResult
    func open(_ descriptor: SystemSettingsDeepLinkDescriptor) -> Bool
}

@MainActor
final class WorkspacePermissionRecoveryOpener: PermissionRecoveryOpening {
    func open(_ descriptor: SystemSettingsDeepLinkDescriptor) -> Bool {
        NSWorkspace.shared.open(descriptor.url)
    }
}

struct PermissionCollectorState: Identifiable, Equatable {
    let collector: CollectorKind
    let consent: CollectorConsentStatus
    let authorization: AuthorizationState
    let isRequesting: Bool
    let isSavingControl: Bool
    let recovery: SystemSettingsDeepLinkDescriptor?
    let message: String?

    var id: CollectorKind { collector }
}

@MainActor
final class PermissionOnboardingModel: ObservableObject {
    static let disclosureVersion = "dayday-consent-v1"

    /// Calendar and Reminders are no longer Dayday collection features. Keep
    /// their legacy consent records readable for compatibility, but exclude
    /// them from the user-facing collection surface and permission polling.
    static let collectionStatusCollectors = CollectorKind.allCases.filter {
        $0 != .calendar && $0 != .reminders
    }
    static let collectionStatusPermissions = PlatformPermissionKind.allCases.filter { permission in
        collectionStatusCollectors.contains { collector in
            guard case let .tcc(requiredPermission) = collector.consentDisclosure.permissionRequirement
            else { return false }
            return requiredPermission == permission
        }
    }

    @Published private(set) var collectorStates: [PermissionCollectorState]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isFirstRunPresented: Bool

    private let repository: any CollectorConsentRepository
    private let requester: any PermissionRequesting
    private let statusProvider: any PermissionAuthorizationStatusProviding
    private let recoveryOpener: any PermissionRecoveryOpening
    private let now: @Sendable () -> Date
    private let promptObservationDelay: Duration
    private let promptObservationAttempts: Int

    private var consents: [CollectorKind: CollectorConsent]
    private var authorizations: [PlatformPermissionKind: AuthorizationState] = [:]
    private var recoveries: [CollectorKind: SystemSettingsDeepLinkDescriptor] = [:]
    private var messages: [CollectorKind: String] = [:]
    private var requestingPermissions: Set<PlatformPermissionKind> = []
    private var savingControls: Set<CollectorKind> = []
    /// Changes whenever an explicit request begins or publishes a result. A status refresh may
    /// only publish facts for permissions whose revision is unchanged since that refresh began.
    private var permissionRevisions: [PlatformPermissionKind: UInt64] = [:]
    private var refreshTask: Task<Void, Never>?
    private var screenCaptureConsentChangeHandler: (@MainActor @Sendable (CollectorConsent) -> Void)?
    private var weatherConsentChangeHandler: (@MainActor @Sendable (CollectorConsent) -> Void)?
    private var applicationWindowControlHandler:
        (@MainActor @Sendable (CollectorConsentAction) async throws -> PersistedCollectorConsent)?
    private var inputControlHandler:
        (@MainActor @Sendable (CollectorKind, CollectorConsentAction) async throws
            -> PersistedCollectorConsent)?
    /// Production persistence for collectors that do not own a dedicated
    /// runtime-control ordering path. This keeps the Settings presentation
    /// independent from SQLite while still making every explicit choice durable.
    private var persistedCollectorControlHandler:
        (@MainActor @Sendable (CollectorKind, CollectorConsentAction) async throws
            -> PersistedCollectorConsent)?
    private var inputGateRefreshHandler: (@MainActor @Sendable () -> Void)?

    init(
        repository: any CollectorConsentRepository = InMemoryCollectorConsentRepository(),
        requester: any PermissionRequesting = ExplicitPermissionRequester(),
        statusProvider: any PermissionAuthorizationStatusProviding = LivePermissionAuthorizationStatusProvider(),
        recoveryOpener: any PermissionRecoveryOpening = WorkspacePermissionRecoveryOpener(),
        now: @escaping @Sendable () -> Date = Date.init,
        promptObservationDelay: Duration = .seconds(1),
        promptObservationAttempts: Int = 12
    ) {
        precondition(promptObservationAttempts > 0)
        self.repository = repository
        self.requester = requester
        self.statusProvider = statusProvider
        self.recoveryOpener = recoveryOpener
        self.now = now
        self.promptObservationDelay = promptObservationDelay
        self.promptObservationAttempts = promptObservationAttempts

        let initialConsents = Dictionary(uniqueKeysWithValues: CollectorKind.allCases.map { collector in
            (collector, repository.consent(for: collector))
        })
        consents = initialConsents
        collectorStates = []
        isFirstRunPresented = Self.collectionStatusCollectors.contains {
            initialConsents[$0]?.status == .unconfirmed
        }
        rebuildStates()
    }

    deinit {
        refreshTask?.cancel()
    }

    var hasUnconfirmedCollectors: Bool {
        Self.collectionStatusCollectors.contains { consents[$0]?.status == .unconfirmed }
    }

    var unconfirmedCollectorCount: Int {
        Self.collectionStatusCollectors.count { consents[$0]?.status == .unconfirmed }
    }

    var enabledCollectorCount: Int {
        Self.collectionStatusCollectors.count { consents[$0]?.status == .enabled }
    }

    var collectorCount: Int { Self.collectionStatusCollectors.count }

    var displayedCollectorStates: [PermissionCollectorState] {
        collectorStates.filter { Self.collectionStatusCollectors.contains($0.collector) }
    }

    /// Composition-only bridge to the Capture-owned runtime. Installing it
    /// immediately publishes the persisted screen consent and never forwards a
    /// different collector's setting.
    func setScreenCaptureConsentChangeHandler(
        _ handler: (@MainActor @Sendable (CollectorConsent) -> Void)?
    ) {
        screenCaptureConsentChangeHandler = handler
        guard let handler else { return }
        guard let consent = consents[.screenUnderstanding] else {
            preconditionFailure("Permission onboarding owns screen consent")
        }
        handler(consent)
    }

    /// The production App installs this only for the H1 application/window
    /// collector. The handler owns durable control ordering and runtime
    /// admission; this UI model never talks to SQLite directly.
    func setApplicationWindowControlHandler(
        _ handler: (@MainActor @Sendable (CollectorConsentAction) async throws
            -> PersistedCollectorConsent)?
    ) {
        applicationWindowControlHandler = handler
    }

    func setInputControlHandler(
        _ handler: (@MainActor @Sendable (CollectorKind, CollectorConsentAction) async throws
            -> PersistedCollectorConsent)?
    ) {
        inputControlHandler = handler
    }

    func setPersistedCollectorControlHandler(
        _ handler: (@MainActor @Sendable (CollectorKind, CollectorConsentAction) async throws
            -> PersistedCollectorConsent)?
    ) {
        persistedCollectorControlHandler = handler
    }

    func setInputGateRefreshHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        inputGateRefreshHandler = handler
    }

    func setWeatherConsentChangeHandler(
        _ handler: (@MainActor @Sendable (CollectorConsent) -> Void)?
    ) {
        weatherConsentChangeHandler = handler
    }

    func applyPersistedApplicationWindowConsent(_ persisted: PersistedCollectorConsent) {
        applyPersistedConsent(persisted)
    }

    func applyPersistedInputConsent(_ persisted: PersistedCollectorConsent) {
        guard persisted.consent.collector == .keyboardAggregates
            || persisted.consent.collector == .pointerAggregates else {
            preconditionFailure("Input consent bridge accepts only keyboard or pointer collectors")
        }
        applyPersistedConsent(persisted)
    }

    /// Restores an already-durable product decision. It deliberately does not
    /// request macOS permission or start a collector; those are separate,
    /// non-prompting runtime responsibilities.
    func applyPersistedConsent(_ persisted: PersistedCollectorConsent) {
        let collector = persisted.consent.collector
        consents[collector] = persisted.consent
        messages[collector] = persisted.renewalRequired
            ? "采集说明已更新；请重新确认后再启用。"
            : nil
        // The production composition restores each saved decision after the
        // view model has been constructed with an in-memory placeholder.
        // Once every collector has a durable decision, this is a returning
        // user rather than a first-run flow, so do not show the onboarding
        // sheet again on every application launch.
        if !hasUnconfirmedCollectors {
            isFirstRunPresented = false
        }
        rebuildStates()
    }

    func state(for collector: CollectorKind) -> PermissionCollectorState {
        guard let state = collectorStates.first(where: { $0.collector == collector }) else {
            preconditionFailure("Permission onboarding must expose every collector")
        }
        return state
    }

    func dismissFirstRun() {
        isFirstRunPresented = false
    }

    func presentFirstRun() {
        isFirstRunPresented = true
    }

    func enable(_ collector: CollectorKind) {
        transition(collector, action: .enable)
    }

    func disable(_ collector: CollectorKind) {
        transition(collector, action: .disable)
    }

    func pause(_ collector: CollectorKind) {
        transition(collector, action: .pause)
    }

    func resume(_ collector: CollectorKind) {
        transition(collector, action: .resume)
    }

    /// Refreshes closed permission facts only. This path cannot invoke a TCC request API.
    func refreshSystemStatuses() {
        guard refreshTask == nil else { return }

        isRefreshing = true
        let provider = statusProvider
        let revisionsAtStart = permissionRevisions
        refreshTask = Task { [weak self] in
            var refreshed: [PlatformPermissionKind: AuthorizationState] = [:]
            for permission in Self.collectionStatusPermissions {
                guard !Task.isCancelled else {
                    self?.finishRefresh(nil, revisionsAtStart: revisionsAtStart)
                    return
                }
                refreshed[permission] = await provider.authorizationStatus(for: permission)
            }
            self?.finishRefresh(
                Task.isCancelled ? nil : refreshed,
                revisionsAtStart: revisionsAtStart
            )
        }
    }

    /// The view calls this only from the confirmation action belonging to the
    /// specific collector's "Request system permission" button.
    func requestSystemPermission(for collector: CollectorKind) async {
        guard let consent = consents[collector], consent.status == .enabled else {
            messages[collector] = "请先确认启用此项，再请求 macOS 权限。"
            rebuildStates()
            return
        }
        guard case let .tcc(permission) = collector.consentDisclosure.permissionRequirement else {
            messages[collector] = "此项不需要 macOS 系统权限。"
            rebuildStates()
            return
        }
        guard !requestingPermissions.contains(permission) else { return }

        requestingPermissions.insert(permission)
        advanceRevision(for: permission)
        messages[collector] = nil
        rebuildStates()
        defer {
            requestingPermissions.remove(permission)
            rebuildStates()
        }

        let outcome = await requester.requestPermission(
            for: consent,
            trigger: .userInitiated
        )
        apply(outcome, to: collector)
        if case .completed(authorization: .unknown, recovery: _) = outcome {
            await observeAuthorizationAfterPrompt(for: collector, permission: permission)
        }
    }

    func openRecovery(for collector: CollectorKind) {
        guard let recovery = state(for: collector).recovery else { return }
        if !recoveryOpener.open(recovery) {
            messages[collector] = "无法打开系统设置，请手动前往“隐私与安全性”。"
            rebuildStates()
        }
    }

    private enum ConsentTransition {
        case enable
        case disable
        case pause
        case resume
    }

    private func transition(_ collector: CollectorKind, action: ConsentTransition) {
        guard let previous = consents[collector] else { return }
        guard !savingControls.contains(collector) else { return }

        do {
            let confirmation = try UserConsentConfirmation(
                collector: collector,
                confirmedAt: now(),
                disclosureVersion: Self.disclosureVersion
            )
            let consentAction: CollectorConsentAction = switch action {
            case .enable: .enable(confirmation)
            case .disable: .disable(confirmation)
            case .pause: .pause(confirmation)
            case .resume: .resume(confirmation)
            }
            let updated = try CollectorConsentStateMachine.transition(
                consentAction,
                from: previous
            )
            if collector == .applicationWindowContext,
               let applicationWindowControlHandler {
                savingControls.insert(collector)
                messages[collector] = "正在安全保存此项设置…"
                rebuildStates()
                Task { [weak self] in
                    defer {
                        self?.savingControls.remove(collector)
                    }
                    do {
                        let persisted = try await applicationWindowControlHandler(consentAction)
                        self?.consents[collector] = persisted.consent
                        self?.messages[collector] = persisted.renewalRequired
                            ? "采集说明已更新；请重新确认后再启用。"
                            : nil
                    } catch {
                        self?.messages[collector] = "未能安全保存此项设置；记录已保持停止。"
                    }
                    self?.rebuildStates()
                }
                return
            }
            if (collector == .keyboardAggregates || collector == .pointerAggregates),
               let inputControlHandler {
                savingControls.insert(collector)
                messages[collector] = "正在安全保存此项设置…"
                rebuildStates()
                Task { [weak self] in
                    defer { self?.savingControls.remove(collector) }
                    do {
                        let persisted = try await inputControlHandler(collector, consentAction)
                        self?.consents[collector] = persisted.consent
                        self?.messages[collector] = persisted.renewalRequired
                            ? "采集说明已更新；请重新确认后再启用。"
                            : nil
                        self?.inputGateRefreshHandler?()
                    } catch {
                        self?.messages[collector] = "未能安全保存此项设置；记录已保持停止。"
                    }
                    self?.rebuildStates()
                }
                return
            }
            if let persistedCollectorControlHandler {
                savingControls.insert(collector)
                messages[collector] = "正在安全保存此项设置…"
                rebuildStates()
                Task { [weak self] in
                    defer { self?.savingControls.remove(collector) }
                    do {
                        let persisted = try await persistedCollectorControlHandler(
                            collector, consentAction
                        )
                        self?.applyPersistedConsent(persisted)
                    } catch {
                        self?.messages[collector] = "未能安全保存此项设置；记录已保持停止。"
                    }
                    self?.rebuildStates()
                }
                return
            }
            try repository.save(updated)
            consents[collector] = updated
            messages[collector] = nil
            if collector == .screenUnderstanding {
                screenCaptureConsentChangeHandler?(updated)
            }
            if collector == .weather {
                weatherConsentChangeHandler?(updated)
            }
        } catch {
            messages[collector] = "未能更新此项设置，请重试。"
        }
        rebuildStates()
    }

    private func apply(_ outcome: PermissionRequestOutcome, to collector: CollectorKind) {
        switch outcome {
        case .notRequired:
            messages[collector] = "此项不需要 macOS 系统权限。"
        case let .notRequested(reason):
            switch reason {
            case .requiresUserInitiatedAction:
                messages[collector] = "权限请求必须由你的明确操作触发。"
            case .productConsentNotEnabled:
                messages[collector] = "请先确认启用此项。"
            }
        case let .completed(authorization, recovery):
            if case let .tcc(permission) = collector.consentDisclosure.permissionRequirement {
                advanceRevision(for: permission)
                authorizations[permission] = authorization
            }
            recoveries[collector] = recovery
            if consents[collector]?.status == .enabled {
                switch authorization {
                case .authorized, .notRequired:
                    messages[collector] = "macOS 权限已就绪。"
                case .unknown, .notDetermined:
                    messages[collector] = "正在等待 macOS 授权结果；此时不会开始采集。"
                default:
                    messages[collector] = "macOS 尚未授权；你可以前往系统设置恢复。"
                }
            } else {
                messages[collector] = "macOS 权限状态已更新；此采集项仍保持暂停或停用。"
            }
        }
        if collector == .keyboardAggregates || collector == .pointerAggregates {
            inputGateRefreshHandler?()
        }
        // Publish the request result before an indeterminate synchronous prompt
        // enters its follow-up polling loop. Otherwise the UI keeps rendering the
        // stale pre-request badge until polling finishes.
        rebuildStates()
    }

    /// Synchronous Screen Recording, Accessibility and Input Monitoring
    /// requests may return before the system prompt is answered. Poll only
    /// after that explicit request so launch and ordinary refresh paths remain
    /// non-prompting.
    private func observeAuthorizationAfterPrompt(
        for collector: CollectorKind,
        permission: PlatformPermissionKind
    ) async {
        let revision = permissionRevisions[permission, default: 0]
        for _ in 0..<promptObservationAttempts {
            guard consents[collector]?.status == .enabled,
                  permissionRevisions[permission, default: 0] == revision else { return }
            try? await Task.sleep(for: promptObservationDelay)
            guard !Task.isCancelled else { return }
            let authorization = await statusProvider.authorizationStatus(for: permission)
            guard permissionRevisions[permission, default: 0] == revision else { return }
            guard authorization != .unknown else { continue }
            authorizations[permission] = authorization
            recoveries[collector] = authorization.needsSystemSettingsRecovery
                ? SystemSettingsDeepLinkDescriptor(permission: permission)
                : nil
            messages[collector] = authorization.permitsCollection
                ? "macOS 权限已就绪。"
                : "macOS 尚未授权；你可以前往系统设置恢复。"
            rebuildStates()
            return
        }
        recoveries[collector] = SystemSettingsDeepLinkDescriptor(permission: permission)
        messages[collector] = "尚未收到 macOS 授权结果；你可以再次请求或打开系统设置。"
        rebuildStates()
    }

    private func finishRefresh(
        _ refreshed: [PlatformPermissionKind: AuthorizationState]?,
        revisionsAtStart: [PlatformPermissionKind: UInt64]
    ) {
        if let refreshed {
            for (permission, status) in refreshed {
                guard permissionRevisions[permission, default: 0]
                    == revisionsAtStart[permission, default: 0] else {
                    continue
                }
                // Screen recording, Accessibility and Input Monitoring preflight APIs cannot
                // distinguish an initial state from a denial. Do not let that closed `unknown`
                // fact erase a more specific result observed after the user's explicit request.
                if status != .unknown || authorizations[permission] == nil {
                    authorizations[permission] = status
                }
            }
        }
        isRefreshing = false
        refreshTask = nil
        rebuildStates()
    }

    private func rebuildStates() {
        collectorStates = CollectorKind.allCases.map { collector in
            let requirement = collector.consentDisclosure.permissionRequirement
            let authorization: AuthorizationState
            let recovery: SystemSettingsDeepLinkDescriptor?

            switch requirement {
            case .notRequired:
                authorization = .notRequired
                recovery = nil
            case let .tcc(permission):
                authorization = authorizations[permission] ?? .unknown
                recovery = recoveries[collector]
                    ?? (authorization.needsSystemSettingsRecovery
                        ? SystemSettingsDeepLinkDescriptor(permission: permission)
                        : nil)
            }

            return PermissionCollectorState(
                collector: collector,
                consent: consents[collector]?.status ?? .unconfirmed,
                authorization: authorization,
                isRequesting: requirement.permission.map(requestingPermissions.contains) ?? false,
                isSavingControl: savingControls.contains(collector),
                recovery: recovery,
                message: messages[collector]
            )
        }
    }

    private func advanceRevision(for permission: PlatformPermissionKind) {
        permissionRevisions[permission, default: 0] &+= 1
    }
}

private extension CollectorPermissionRequirement {
    var permission: PlatformPermissionKind? {
        guard case let .tcc(permission) = self else { return nil }
        return permission
    }
}

private extension AuthorizationState {
    var needsSystemSettingsRecovery: Bool {
        switch self {
        case .denied, .restricted, .revoked, .insufficientAccess:
            return true
        case .notRequired, .notDetermined, .authorized, .unknown:
            return false
        }
    }
}
