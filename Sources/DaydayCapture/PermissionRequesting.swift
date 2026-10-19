@preconcurrency import ApplicationServices
import CoreGraphics
import DaydayCore
import EventKit
import Foundation

/// Why a caller reached the permission coordinator. Only `userInitiated` may
/// cross the boundary into a macOS request API.
public enum PermissionRequestTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case userInitiated
    case applicationLaunch
    case authorizationPreflight
    case automaticResume
}

enum PlatformPermissionRequestResult: String, Codable, CaseIterable, Hashable, Sendable {
    case authorized
    case denied
    case restricted
    case revoked
    case insufficientAccess
    case unknown

    var authorizationState: AuthorizationState {
        switch self {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .revoked:
            return .revoked
        case .insufficientAccess:
            return .insufficientAccess
        case .unknown:
            return .unknown
        }
    }
}

/// Injectable platform boundary. Implementations may present a macOS TCC prompt,
/// so callers must go through `ExplicitPermissionRequester` rather than invoke
/// an adapter from launch, preflight, or resume code.
protocol PlatformPermissionRequestAdapting: Sendable {
    func request(_ permission: PlatformPermissionKind) async -> PlatformPermissionRequestResult
}

/// A descriptor only; constructing it never opens System Settings.
public struct SystemSettingsDeepLinkDescriptor: Codable, Equatable, Hashable, Sendable {
    public let permission: PlatformPermissionKind

    /// The destination is derived from the closed permission fact instead of
    /// being decoded as caller-controlled data.
    public var url: URL {
        URL(string: permission.systemSettingsURLString)!
    }

    public init(permission: PlatformPermissionKind) {
        self.permission = permission
    }
}

public enum PermissionRequestBlockReason: Equatable, Hashable, Sendable {
    case requiresUserInitiatedAction(PermissionRequestTrigger)
    case productConsentNotEnabled(CollectorConsentStatus)
}

public enum PermissionRequestOutcome: Equatable, Hashable, Sendable {
    case notRequested(PermissionRequestBlockReason)
    case notRequired
    case completed(
        authorization: AuthorizationState,
        recovery: SystemSettingsDeepLinkDescriptor?
    )
}

public protocol PermissionRequesting: Sendable {
    func requestPermission(
        for consent: CollectorConsent,
        trigger: PermissionRequestTrigger
    ) async -> PermissionRequestOutcome
}

/// The only production entry point for prompting TCC permissions. It neither
/// configures nor starts a collector; it returns an authorization fact for the
/// existing state machine to consume separately.
public struct ExplicitPermissionRequester: PermissionRequesting, Sendable {
    private let adapter: any PlatformPermissionRequestAdapting

    /// The only public construction path. The prompt-capable adapter remains
    /// module-internal so other modules cannot bypass the policy gateway.
    public init() {
        self.adapter = MacOSPlatformPermissionRequestAdapter()
    }

    init(adapter: any PlatformPermissionRequestAdapting) {
        self.adapter = adapter
    }

    public func requestPermission(
        for consent: CollectorConsent,
        trigger: PermissionRequestTrigger
    ) async -> PermissionRequestOutcome {
        guard trigger == .userInitiated else {
            return .notRequested(.requiresUserInitiatedAction(trigger))
        }
        guard consent.permitsPermissionRequest else {
            return .notRequested(.productConsentNotEnabled(consent.status))
        }

        switch consent.collector.consentDisclosure.permissionRequirement {
        case .notRequired:
            return .notRequired
        case let .tcc(permission):
            let result = await adapter.request(permission)
            let authorization = result.authorizationState
            return .completed(
                authorization: authorization,
                recovery: authorization.permitsCollection
                    ? nil
                    : SystemSettingsDeepLinkDescriptor(permission: permission)
            )
        }
    }
}

/// Real macOS adapters. Every closure is stored as `@Sendable` and invoked only
/// after `ExplicitPermissionRequester` has admitted an explicit user action.
struct MacOSPlatformPermissionRequestAdapter: PlatformPermissionRequestAdapting, Sendable {
    private let screenRecordingRequest: @Sendable () -> PlatformPermissionRequestResult
    private let accessibilityRequest: @Sendable () -> PlatformPermissionRequestResult
    private let inputMonitoringRequest: @Sendable () -> PlatformPermissionRequestResult
    private let calendarRequest: @Sendable () async -> PlatformPermissionRequestResult
    private let remindersRequest: @Sendable () async -> PlatformPermissionRequestResult

    init() {
        screenRecordingRequest = {
            Self.indeterminatePromptResult(
                isAuthorized: CGRequestScreenCaptureAccess()
            )
        }
        accessibilityRequest = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            // This API asks macOS to present its UI but returns immediately.
            // A false value therefore means only "not trusted yet"; it cannot
            // distinguish a visible prompt from an explicit user refusal.
            return Self.accessibilityResult(
                isTrusted: AXIsProcessTrustedWithOptions(options)
            )
        }
        inputMonitoringRequest = {
            Self.indeterminatePromptResult(
                isAuthorized: CGRequestListenEventAccess()
            )
        }
        calendarRequest = {
            let eventStore = EKEventStore()
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                return granted
                    ? .authorized
                    : Self.eventKitResult(for: .event)
            } catch {
                return Self.eventKitResult(for: .event)
            }
        }
        remindersRequest = {
            let eventStore = EKEventStore()
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                return granted
                    ? .authorized
                    : Self.eventKitResult(for: .reminder)
            } catch {
                return Self.eventKitResult(for: .reminder)
            }
        }
    }

    func request(
        _ permission: PlatformPermissionKind
    ) async -> PlatformPermissionRequestResult {
        switch permission {
        case .screenRecording:
            return screenRecordingRequest()
        case .accessibility:
            return accessibilityRequest()
        case .inputMonitoring:
            return inputMonitoringRequest()
        case .calendar:
            return await calendarRequest()
        case .reminders:
            return await remindersRequest()
        }
    }

    static func eventKitResult(for entityType: EKEntityType) -> PlatformPermissionRequestResult {
        eventKitResult(for: EKEventStore.authorizationStatus(for: entityType))
    }

    static func accessibilityResult(isTrusted: Bool) -> PlatformPermissionRequestResult {
        indeterminatePromptResult(isAuthorized: isTrusted)
    }

    /// The synchronous CoreGraphics and Accessibility request APIs return
    /// before the user necessarily acts on the visible macOS prompt. `false`
    /// therefore means only "not authorized yet", never a proven refusal.
    static func indeterminatePromptResult(
        isAuthorized: Bool
    ) -> PlatformPermissionRequestResult {
        isAuthorized ? .authorized : .unknown
    }

    static func eventKitResult(
        for authorizationStatus: EKAuthorizationStatus
    ) -> PlatformPermissionRequestResult {
        switch authorizationStatus {
        case .fullAccess, .authorized:
            return .authorized
        case .writeOnly:
            return .insufficientAccess
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}

private extension PlatformPermissionKind {
    var systemSettingsURLString: String {
        let anchor: String
        switch self {
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        case .calendar:
            anchor = "Privacy_Calendars"
        case .reminders:
            anchor = "Privacy_Reminders"
        }
        return "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
    }
}
