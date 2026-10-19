import DaydayCore
import Testing
@testable import DaydayCapture

struct CollectorCoordinatorTests {
    @Test
    func snapshotIncludesEveryCollectorWithoutInventingRuntimeActivity() {
        let coordinator = CollectorCoordinator()

        #expect(coordinator.snapshot.collectors.map(\.kind) == CollectorKind.allCases)
        #expect(coordinator.snapshot.configuredCollectors.isEmpty)
        #expect(!coordinator.snapshot.isApplicationPaused)
        #expect(coordinator.snapshot.state(for: .screenUnderstanding).authorization == .notDetermined)
        #expect(coordinator.snapshot.state(for: .screenUnderstanding).runtime == .unconfigured)
    }

    @Test
    func configureAndAuthorizationChangesUseTheCoreStateMachine() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .denied,
        ])

        let configured = try coordinator.apply(.configure, to: .screenUnderstanding)
        #expect(configured.changedKinds == [.screenUnderstanding])
        #expect(configured.current.state(for: .screenUnderstanding).runtime == .waitingForAuthorization)

        let authorized = try coordinator.apply(
            .authorizationChanged(.authorized),
            to: .screenUnderstanding
        )
        #expect(authorized.current.state(for: .screenUnderstanding).runtime == .running)
        #expect(!authorized.requiresSessionBoundary)
    }

    @Test
    func repeatedCommandsAreIdempotent() throws {
        var coordinator = CollectorCoordinator(authorizations: [.weather: .notRequired])

        _ = try coordinator.apply(.configure, to: .weather)
        let repeatedConfigure = try coordinator.apply(.configure, to: .weather)
        #expect(repeatedConfigure.changedKinds.isEmpty)

        _ = try coordinator.apply(.degrade(.dependencyUnavailable), to: .weather)
        let repeatedDegrade = try coordinator.apply(.degrade(.dependencyUnavailable), to: .weather)
        #expect(repeatedDegrade.changedKinds.isEmpty)

        _ = try coordinator.apply(.recover, to: .weather)
        let repeatedRecover = try coordinator.apply(.recover, to: .weather)
        #expect(repeatedRecover.changedKinds.isEmpty)
        #expect(repeatedRecover.current.state(for: .weather).runtime == .running)
    }

    @Test
    func failureAndRecoveryRemainPausedUntilEverySuppressionClears() throws {
        var coordinator = CollectorCoordinator(authorizations: [.weather: .notRequired])
        _ = try coordinator.apply(.configure, to: .weather)
        _ = try coordinator.setSystemSleeping(true)

        let failed = try coordinator.apply(.fail(.serviceUnavailable), to: .weather)
        #expect(failed.current.state(for: .weather).runtime == .paused(
            reasons: [.systemSleep],
            resumeState: .failed(.serviceUnavailable)
        ))

        _ = try coordinator.apply(.recover, to: .weather)
        let repeatedRecovery = try coordinator.apply(.recover, to: .weather)
        #expect(repeatedRecovery.changedKinds.isEmpty)
        #expect(repeatedRecovery.current.state(for: .weather).runtime == .paused(
            reasons: [.systemSleep],
            resumeState: .running
        ))

        let woke = try coordinator.setSystemSleeping(false)
        #expect(woke.current.state(for: .weather).runtime == .running)
    }

    @Test
    func invalidBatchLeavesEveryCollectorUnchanged() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)
        let before = coordinator.snapshot

        #expect(throws: CollectorCoordinatorError.transitionRejected(
            kind: .chromeContext,
            reason: .cannotRecover(.unconfigured)
        )) {
            try coordinator.apply([
                .screenUnderstanding: .degrade(.resourcePressure),
                .chromeContext: .recover,
            ])
        }
        #expect(coordinator.snapshot == before)
    }

    @Test
    func applicationPauseAtomicallyBroadcastsOnlyToConfiguredCollectors() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
            .keyboardAggregates: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)
        _ = try coordinator.apply(.configure, to: .keyboardAggregates)

        let paused = try coordinator.setGlobalPause(true)

        #expect(paused.changedKinds == [.screenUnderstanding, .keyboardAggregates])
        #expect(paused.sessionBoundaryKinds == [.screenUnderstanding, .keyboardAggregates])
        #expect(paused.current.activeApplicationPauseReasons == [.globalUserPause])
        #expect(paused.current.state(for: .screenUnderstanding).runtime == .paused(
            reasons: [.globalUserPause],
            resumeState: .running
        ))
        #expect(paused.current.state(for: .weather).runtime == .unconfigured)

        let duplicate = try coordinator.setGlobalPause(true)
        #expect(duplicate.changedKinds.isEmpty)
        #expect(duplicate.sessionBoundaryKinds.isEmpty)

        let resumed = try coordinator.setGlobalPause(false)
        #expect(resumed.current.state(for: .keyboardAggregates).runtime == .running)
        #expect(!resumed.current.isApplicationPaused)
        #expect(!resumed.requiresSessionBoundary)
    }

    @Test
    func sessionScreensAndSystemSleepRemainIndependentAcrossAllCollectors() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .applicationWindowContext: .authorized,
            .weather: .notRequired,
        ])
        _ = try coordinator.apply(.configure, to: .applicationWindowContext)
        _ = try coordinator.apply(.configure, to: .weather)

        _ = try coordinator.setUserSessionActive(false)
        _ = try coordinator.setScreensAwake(false)
        let sleeping = try coordinator.setSystemSleeping(true)
        #expect(sleeping.current.activeApplicationPauseReasons == [
            .userSessionInactive,
            .screensAsleep,
            .systemSleep,
        ])
        #expect(sleeping.sessionBoundaryKinds.isEmpty)

        let woke = try coordinator.setSystemSleeping(false)
        #expect(woke.current.state(for: .weather).runtime == .paused(
            reasons: [.userSessionInactive, .screensAsleep],
            resumeState: .running
        ))

        _ = try coordinator.setUserSessionActive(true)
        let screensWoke = try coordinator.setScreensAwake(true)
        #expect(screensWoke.current.state(for: .applicationWindowContext).runtime == .running)
    }

    @Test
    func configuringDuringGlobalPauseNeverExposesAFalseRunningSnapshot() throws {
        var coordinator = CollectorCoordinator(authorizations: [.weather: .notRequired])
        _ = try coordinator.setGlobalPause(true)

        let configured = try coordinator.apply(.configure, to: .weather)

        #expect(configured.previous.state(for: .weather).runtime == .unconfigured)
        #expect(configured.current.state(for: .weather).runtime == .paused(
            reasons: [.globalUserPause],
            resumeState: .running
        ))
        #expect(configured.changedKinds == [.weather])
        #expect(!configured.requiresSessionBoundary)
    }

    @Test
    func collectorScopedPauseCoexistsWithApplicationLifecyclePauses() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)
        _ = try coordinator.apply(.pause(.privacyExclusion), to: .screenUnderstanding)
        _ = try coordinator.setScreenLocked(true)
        _ = try coordinator.setScreenLocked(false)

        #expect(coordinator.snapshot.state(for: .screenUnderstanding).runtime == .paused(
            reasons: [.privacyExclusion],
            resumeState: .running
        ))
    }

    @Test
    func applicationWideReasonsCannotBeChangedForOnlyOneCollector() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)
        let before = coordinator.snapshot

        #expect(throws: CollectorCoordinatorError.applicationWideReasonRequiresBroadcast(
            .screenLocked
        )) {
            try coordinator.apply(.pause(.screenLocked), to: .screenUnderstanding)
        }
        #expect(coordinator.snapshot == before)
    }

    @Test
    func revocationWhilePausedFailsClosedAfterResume() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)
        _ = try coordinator.setScreenLocked(true)
        _ = try coordinator.apply(
            .authorizationChanged(.revoked),
            to: .screenUnderstanding
        )

        let unlocked = try coordinator.setScreenLocked(false)
        #expect(unlocked.current.state(for: .screenUnderstanding).authorization == .revoked)
        #expect(unlocked.current.state(for: .screenUnderstanding).runtime == .waitingForAuthorization)
    }

    @Test
    func revokingAuthorizationWhileRunningReportsTheCollectorBoundary() throws {
        var coordinator = CollectorCoordinator(authorizations: [
            .screenUnderstanding: .authorized,
        ])
        _ = try coordinator.apply(.configure, to: .screenUnderstanding)

        let revoked = try coordinator.apply(
            .authorizationChanged(.revoked),
            to: .screenUnderstanding
        )

        #expect(revoked.changedKinds == [.screenUnderstanding])
        #expect(revoked.sessionBoundaryKinds == [.screenUnderstanding])
        #expect(revoked.current.state(for: .screenUnderstanding).runtime == .waitingForAuthorization)
    }
}
