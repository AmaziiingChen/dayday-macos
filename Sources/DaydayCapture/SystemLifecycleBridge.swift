import AppKit
import CoreGraphics
import DaydayCore
import Foundation

/// Objective macOS lifecycle facts that suppress collection while the system
/// or the current graphical session is unavailable.
public enum SystemLifecycleEvent: Equatable, Sendable {
    case systemWillSleep
    case systemDidWake
    case userSessionDidResignActive
    case userSessionDidBecomeActive
    case screensDidSleep
    case screensDidWake
}

/// Initial objective availability read before collection can be considered active.
/// Unknown or incomplete platform state must be represented as unavailable.
public struct SystemLifecycleAvailability: Equatable, Sendable {
    public let isUserSessionActive: Bool
    public let areScreensAwake: Bool

    public init(isUserSessionActive: Bool, areScreensAwake: Bool) {
        self.isUserSessionActive = isUserSessionActive
        self.areScreensAwake = areScreensAwake
    }
}

/// A cancellable registration returned by a lifecycle notification source.
///
/// The source, observation, and bridge are main-actor isolated so notification
/// delivery cannot race coordinator mutation.
@MainActor
public protocol SystemLifecycleObservation: AnyObject {
    func cancel()
}

/// Injectable boundary around the platform notification mechanism.
@MainActor
public protocol SystemLifecycleNotificationSource: AnyObject {
    func currentAvailability() -> SystemLifecycleAvailability

    func observe(
        _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
    ) -> any SystemLifecycleObservation
}

/// Production notification source backed by `NSWorkspace.notificationCenter`.
@MainActor
public final class NSWorkspaceSystemLifecycleNotificationSource:
    SystemLifecycleNotificationSource
{
    private let notificationCenter: NotificationCenter
    private let availabilityProvider: @MainActor @Sendable () -> SystemLifecycleAvailability

    public convenience init() {
        self.init(
            notificationCenter: NSWorkspace.shared.notificationCenter,
            availabilityProvider: Self.platformAvailability
        )
    }

    init(
        notificationCenter: NotificationCenter,
        availabilityProvider: @escaping @MainActor @Sendable () -> SystemLifecycleAvailability
    ) {
        self.notificationCenter = notificationCenter
        self.availabilityProvider = availabilityProvider
    }

    public func currentAvailability() -> SystemLifecycleAvailability {
        availabilityProvider()
    }

    public func observe(
        _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
    ) -> any SystemLifecycleObservation {
        let mappings: [(Notification.Name, SystemLifecycleEvent)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (
                NSWorkspace.sessionDidResignActiveNotification,
                .userSessionDidResignActive
            ),
            (
                NSWorkspace.sessionDidBecomeActiveNotification,
                .userSessionDidBecomeActive
            ),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
        ]

        let tokens = mappings.map { name, event in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    handler(event)
                }
            }
        }
        return NotificationCenterLifecycleObservation(
            notificationCenter: notificationCenter,
            tokens: tokens
        )
    }

    private static func platformAvailability() -> SystemLifecycleAvailability {
        let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isOnConsole = sessionDictionary?[kCGSessionOnConsoleKey as String] as? Bool ?? false
        let isLoginDone = sessionDictionary?[kCGSessionLoginDoneKey as String] as? Bool ?? false

        return SystemLifecycleAvailability(
            isUserSessionActive: isOnConsole && isLoginDone,
            areScreensAwake: anyOnlineDisplayIsAwake()
        )
    }

    private static func anyOnlineDisplayIsAwake() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](
            repeating: kCGNullDirectDisplay,
            count: Int(displayCount)
        )
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }
        return displays.prefix(Int(displayCount)).contains {
            CGDisplayIsAsleep($0) == 0
        }
    }
}

@MainActor
private final class NotificationCenterLifecycleObservation: SystemLifecycleObservation {
    private let storage: NotificationCenterObservationStorage

    init(notificationCenter: NotificationCenter, tokens: [NSObjectProtocol]) {
        storage = NotificationCenterObservationStorage(
            notificationCenter: notificationCenter,
            tokens: tokens
        )
    }

    func cancel() {
        storage.cancel()
    }
}

/// `deinit` is nonisolated in Swift 6. This lock-protected, unchecked-Sendable
/// holder keeps Objective-C observer tokens private while making release-time
/// cancellation safe on whichever executor releases the observation.
private final class NotificationCenterObservationStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol]

    init(notificationCenter: NotificationCenter, tokens: [NSObjectProtocol]) {
        self.notificationCenter = notificationCenter
        self.tokens = tokens
    }

    deinit {
        cancel()
    }

    func cancel() {
        let tokensToRemove = lock.withLock {
            let current = tokens
            tokens.removeAll()
            return current
        }
        for token in tokensToRemove {
            notificationCenter.removeObserver(token)
        }
    }
}

/// Main-actor bridge from macOS lifecycle notifications to collector pauses.
///
/// The bridge owns the coordinator value it receives. Other coordinator
/// mutations should use ``mutateCoordinator(_:)`` so lifecycle events and
/// application commands remain serialized on the same actor.
@MainActor
public final class SystemLifecycleBridge {
    public typealias TransitionHandler = @MainActor @Sendable (
        SystemLifecycleEvent,
        CollectorCoordinatorTransition
    ) -> Void

    public typealias FailureHandler = @MainActor @Sendable (
        SystemLifecycleEvent,
        CollectorCoordinatorError
    ) -> Void

    private let notificationSource: any SystemLifecycleNotificationSource
    private let onTransition: TransitionHandler
    private let onFailure: FailureHandler
    private var observation: (any SystemLifecycleObservation)?
    private var activeObservationID: UUID?
    private var coordinator: CollectorCoordinator

    public private(set) var lastTransition: CollectorCoordinatorTransition?
    public private(set) var lastError: CollectorCoordinatorError?

    public init(
        coordinator: CollectorCoordinator,
        notificationSource: any SystemLifecycleNotificationSource,
        onTransition: @escaping TransitionHandler = { _, _ in },
        onFailure: @escaping FailureHandler = { _, _ in }
    ) {
        self.coordinator = coordinator
        self.notificationSource = notificationSource
        self.onTransition = onTransition
        self.onFailure = onFailure
    }

    public convenience init(
        coordinator: CollectorCoordinator,
        onTransition: @escaping TransitionHandler = { _, _ in },
        onFailure: @escaping FailureHandler = { _, _ in }
    ) {
        self.init(
            coordinator: coordinator,
            notificationSource: NSWorkspaceSystemLifecycleNotificationSource(),
            onTransition: onTransition,
            onFailure: onFailure
        )
    }

    public var snapshot: CollectorCoordinatorSnapshot {
        coordinator.snapshot
    }

    public var isObserving: Bool {
        observation != nil
    }

    /// Starts delivery once. Repeated calls do not create duplicate observers.
    public func start() {
        guard observation == nil else { return }
        let observationID = UUID()
        activeObservationID = observationID
        let newObservation = notificationSource.observe { [weak self] event in
            guard self?.activeObservationID == observationID else { return }
            self?.receive(event)
        }
        guard activeObservationID == observationID else {
            newObservation.cancel()
            return
        }
        observation = newObservation

        // Register first, then read the current objective state. Any notification
        // arriving during the synchronous read is queued on the main actor and
        // reconciles after this fail-closed snapshot is applied.
        let availability = notificationSource.currentAvailability()
        guard activeObservationID == observationID else { return }
        receive(
            availability.isUserSessionActive
                ? .userSessionDidBecomeActive
                : .userSessionDidResignActive
        )
        receive(availability.areScreensAwake ? .screensDidWake : .screensDidSleep)
    }

    /// Cancels every platform observer. Repeated teardown is a no-op.
    public func teardown() {
        // Invalidate delivery before removing observers so a notification that
        // was already queued cannot mutate the coordinator after teardown.
        activeObservationID = nil
        observation?.cancel()
        observation = nil
    }

    /// Serializes non-lifecycle coordinator commands with notification events.
    @discardableResult
    public func mutateCoordinator<T>(
        _ mutation: (inout CollectorCoordinator) throws -> T
    ) rethrows -> T {
        try mutation(&coordinator)
    }

    private func receive(_ event: SystemLifecycleEvent) {
        do {
            let transition: CollectorCoordinatorTransition
            switch event {
            case .systemWillSleep:
                transition = try coordinator.setSystemSleeping(true)
            case .systemDidWake:
                transition = try coordinator.setSystemSleeping(false)
            case .userSessionDidResignActive:
                transition = try coordinator.setUserSessionActive(false)
            case .userSessionDidBecomeActive:
                transition = try coordinator.setUserSessionActive(true)
            case .screensDidSleep:
                transition = try coordinator.setScreensAwake(false)
            case .screensDidWake:
                transition = try coordinator.setScreensAwake(true)
            }

            lastTransition = transition
            lastError = nil
            onTransition(event, transition)
        } catch let error as CollectorCoordinatorError {
            lastTransition = nil
            lastError = error
            onFailure(event, error)
        } catch {
            preconditionFailure("CollectorCoordinator threw an undocumented error: \(error)")
        }
    }
}
