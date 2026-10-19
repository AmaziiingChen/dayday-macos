import AppKit
import DaydayCore
import Testing
@testable import DaydayCapture

@MainActor
@Suite("System lifecycle bridge")
struct SystemLifecycleBridgeTests {
    @Test("workspace notifications map to independent system, session, and screen pauses")
    func workspaceNotificationsMapToCoordinatorPauses() throws {
        let notificationCenter = NotificationCenter()
        let source = NSWorkspaceSystemLifecycleNotificationSource(
            notificationCenter: notificationCenter,
            availabilityProvider: {
                SystemLifecycleAvailability(
                    isUserSessionActive: true,
                    areScreensAwake: true
                )
            }
        )
        let coordinator = try configuredCoordinator()
        let bridge = SystemLifecycleBridge(
            coordinator: coordinator,
            notificationSource: source
        )
        bridge.start()

        notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(bridge.snapshot.activeApplicationPauseReasons == [
            .userSessionInactive,
            .screensAsleep,
            .systemSleep,
        ])

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(bridge.snapshot.activeApplicationPauseReasons == [
            .userSessionInactive,
            .screensAsleep,
        ])

        notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(bridge.snapshot.activeApplicationPauseReasons == [.screensAsleep])
        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(bridge.snapshot.activeApplicationPauseReasons.isEmpty)
        #expect(bridge.snapshot.state(for: .weather).runtime == .running)

        #expect(coordinator.snapshot.state(for: .weather).runtime == .running)
    }

    @Test("duplicate lifecycle facts remain observable no-ops")
    func duplicateEventsAreIdempotent() throws {
        let source = TestNotificationSource()
        var transitions: [CollectorCoordinatorTransition] = []
        let bridge = SystemLifecycleBridge(
            coordinator: try configuredCoordinator(),
            notificationSource: source,
            onTransition: { _, transition in transitions.append(transition) }
        )
        bridge.start()
        transitions.removeAll()

        source.send(.systemWillSleep)
        source.send(.systemWillSleep)

        #expect(transitions.count == 2)
        #expect(!transitions[0].changedKinds.isEmpty)
        #expect(transitions[1].changedKinds.isEmpty)
        #expect(transitions[1].sessionBoundaryKinds.isEmpty)
        #expect(bridge.snapshot.activeApplicationPauseReasons == [.systemSleep])
    }

    @Test("initial unavailable session and screens fail closed before start returns")
    func initialAvailabilityFailsClosed() throws {
        let source = TestNotificationSource(
            availability: SystemLifecycleAvailability(
                isUserSessionActive: false,
                areScreensAwake: false
            )
        )
        let bridge = SystemLifecycleBridge(
            coordinator: try configuredCoordinator(),
            notificationSource: source
        )

        bridge.start()

        #expect(bridge.snapshot.activeApplicationPauseReasons == [
            .userSessionInactive,
            .screensAsleep,
        ])
        #expect(bridge.snapshot.state(for: .weather).runtime == .paused(
            reasons: [.userSessionInactive, .screensAsleep],
            resumeState: .running
        ))
    }

    @Test("start and teardown are idempotent and teardown stops delivery")
    func teardownCancelsDeliveryAndAllowsRestart() throws {
        let source = TestNotificationSource()
        let bridge = SystemLifecycleBridge(
            coordinator: try configuredCoordinator(),
            notificationSource: source
        )

        bridge.start()
        bridge.start()
        #expect(source.observationCount == 1)
        #expect(bridge.isObserving)
        let queuedDelivery = source.queuedDelivery(of: .systemWillSleep)

        bridge.teardown()
        bridge.teardown()
        #expect(source.cancellationCount == 1)
        #expect(!bridge.isObserving)

        source.send(.systemWillSleep)
        queuedDelivery()
        #expect(bridge.snapshot.activeApplicationPauseReasons.isEmpty)

        bridge.start()
        #expect(source.observationCount == 2)
        source.send(.systemWillSleep)
        #expect(bridge.snapshot.activeApplicationPauseReasons == [.systemSleep])
    }

    @Test("application coordinator mutations share main-actor serialization")
    func applicationMutationsUseTheOwnedCoordinator() throws {
        let source = TestNotificationSource()
        let bridge = SystemLifecycleBridge(
            coordinator: CollectorCoordinator(authorizations: [.weather: .notRequired]),
            notificationSource: source
        )

        try bridge.mutateCoordinator { coordinator in
            try coordinator.apply(.configure, to: .weather)
        }
        bridge.start()
        source.send(.userSessionDidResignActive)

        #expect(bridge.snapshot.state(for: .weather).runtime == .paused(
            reasons: [.userSessionInactive],
            resumeState: .running
        ))
    }

    @Test("production observation removes notification tokens when released")
    func productionObservationReleaseCancelsTokens() {
        let notificationCenter = NotificationCenter()
        let source = NSWorkspaceSystemLifecycleNotificationSource(
            notificationCenter: notificationCenter,
            availabilityProvider: {
                SystemLifecycleAvailability(
                    isUserSessionActive: true,
                    areScreensAwake: true
                )
            }
        )
        var events: [SystemLifecycleEvent] = []
        var observation: (any SystemLifecycleObservation)? = source.observe {
            events.append($0)
        }

        notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(events == [.screensDidSleep])

        observation = nil
        #expect(observation == nil)
        notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(events == [.screensDidSleep])
    }

    private func configuredCoordinator() throws -> CollectorCoordinator {
        var coordinator = CollectorCoordinator(authorizations: [.weather: .notRequired])
        try coordinator.apply(.configure, to: .weather)
        return coordinator
    }
}

@MainActor
private final class TestNotificationSource: SystemLifecycleNotificationSource {
    private var handler: (@MainActor @Sendable (SystemLifecycleEvent) -> Void)?
    private(set) var observationCount = 0
    private(set) var cancellationCount = 0
    private var availability: SystemLifecycleAvailability

    init(
        availability: SystemLifecycleAvailability = SystemLifecycleAvailability(
            isUserSessionActive: true,
            areScreensAwake: true
        )
    ) {
        self.availability = availability
    }

    func currentAvailability() -> SystemLifecycleAvailability {
        availability
    }

    func observe(
        _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
    ) -> any SystemLifecycleObservation {
        observationCount += 1
        self.handler = handler
        return TestLifecycleObservation { [weak self] in
            guard let self, self.handler != nil else { return }
            self.handler = nil
            self.cancellationCount += 1
        }
    }

    func send(_ event: SystemLifecycleEvent) {
        handler?(event)
    }

    func queuedDelivery(of event: SystemLifecycleEvent) -> @MainActor () -> Void {
        let queuedHandler = handler
        return {
            queuedHandler?(event)
        }
    }
}

@MainActor
private final class TestLifecycleObservation: SystemLifecycleObservation {
    private var cancellation: (@MainActor () -> Void)?

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}
