import Foundation
import Testing
@testable import DaydayCore

struct CollectorStateTests {
    @Test
    func deniedAuthorizationWaitsWithoutTreatingConsentAsFailure() throws {
        let initial = CollectorState(kind: .screenUnderstanding, authorization: .denied)

        let transition = try CollectorStateMachine.transition(.configure, from: initial)

        #expect(transition.current.authorization == .denied)
        #expect(transition.current.runtime == .waitingForAuthorization)
        #expect(!transition.requiresSessionBoundary)

        let insufficient = try CollectorStateMachine.transition(
            .configure,
            from: CollectorState(kind: .calendar, authorization: .insufficientAccess)
        )
        #expect(insufficient.current.runtime == .waitingForAuthorization)
    }

    @Test
    func revokingAuthorizationStopsAnActiveSession() throws {
        let running = try configuredCollector(kind: .screenUnderstanding)

        let transition = try CollectorStateMachine.transition(
            .authorizationChanged(.revoked),
            from: running
        )

        #expect(transition.current.authorization == .revoked)
        #expect(transition.current.runtime == .waitingForAuthorization)
        #expect(transition.requiresSessionBoundary)
    }

    @Test
    func explicitPauseAndResumeRoundTrip() throws {
        let running = try configuredCollector(kind: .keyboardAggregates)

        let paused = try CollectorStateMachine.transition(
            .pause(.globalUserPause),
            from: running
        )
        #expect(paused.current.runtime == .paused(
            reasons: [.globalUserPause],
            resumeState: .running
        ))
        #expect(paused.requiresSessionBoundary)

        let resumed = try CollectorStateMachine.transition(
            .resume(.globalUserPause),
            from: paused.current
        )
        #expect(resumed.current.runtime == .running)
        #expect(!resumed.requiresSessionBoundary)
    }

    @Test
    func lockAndSleepRemainIndependentHardBoundaries() throws {
        let running = try configuredCollector(kind: .applicationWindowContext)
        let locked = try CollectorStateMachine.transition(
            .pause(.screenLocked),
            from: running
        )
        let sleeping = try CollectorStateMachine.transition(
            .pause(.systemSleep),
            from: locked.current
        )

        #expect(locked.requiresSessionBoundary)
        #expect(!sleeping.requiresSessionBoundary)
        #expect(sleeping.current.runtime == .paused(
            reasons: [.screenLocked, .systemSleep],
            resumeState: .running
        ))

        let woke = try CollectorStateMachine.transition(
            .resume(.systemSleep),
            from: sleeping.current
        )
        #expect(woke.current.runtime == .paused(
            reasons: [.screenLocked],
            resumeState: .running
        ))

        let unlocked = try CollectorStateMachine.transition(
            .resume(.screenLocked),
            from: woke.current
        )
        #expect(unlocked.current.runtime == .running)
    }

    @Test
    func authorizationCanBeRevokedWhilePausedAndResumeFailsClosed() throws {
        let running = try configuredCollector(kind: .screenUnderstanding)
        let paused = try CollectorStateMachine.transition(
            .pause(.screenLocked),
            from: running
        )
        let revoked = try CollectorStateMachine.transition(
            .authorizationChanged(.revoked),
            from: paused.current
        )
        let unlocked = try CollectorStateMachine.transition(
            .resume(.screenLocked),
            from: revoked.current
        )

        #expect(revoked.current.runtime == .paused(
            reasons: [.screenLocked],
            resumeState: .waitingForAuthorization
        ))
        #expect(unlocked.current.runtime == .waitingForAuthorization)
    }

    @Test
    func ordinaryDegradationAndFailureDoNotCutEveryCrossCollectorSession() throws {
        let running = try configuredCollector(kind: .weather)

        let degraded = try CollectorStateMachine.transition(
            .degrade(.dependencyUnavailable),
            from: running
        )
        let failed = try CollectorStateMachine.transition(
            .fail(.serviceUnavailable),
            from: degraded.current
        )

        #expect(degraded.current.runtime == .degraded(.dependencyUnavailable))
        #expect(!degraded.requiresSessionBoundary)
        #expect(failed.current.runtime == .failed(.serviceUnavailable))
        #expect(!failed.requiresSessionBoundary)
    }

    @Test
    func invalidTransitionsAreRejected() throws {
        let unconfigured = CollectorState(kind: .chromeContext, authorization: .authorized)

        #expect(throws: CollectorStateTransitionError.notConfigured) {
            try CollectorStateMachine.transition(.pause(.globalUserPause), from: unconfigured)
        }
        #expect(throws: CollectorStateTransitionError.pauseReasonNotActive(.screenLocked)) {
            try CollectorStateMachine.transition(.resume(.screenLocked), from: unconfigured)
        }

        let running = try CollectorStateMachine.transition(.configure, from: unconfigured).current
        #expect(throws: CollectorStateTransitionError.alreadyConfigured) {
            try CollectorStateMachine.transition(.configure, from: running)
        }
        #expect(throws: CollectorStateTransitionError.cannotRecover(.running)) {
            try CollectorStateMachine.transition(.recover, from: running)
        }
    }

    @Test
    func decodingCannotBypassFailClosedStateInvariants() throws {
        let deniedRunning = Data(#"{"kind":"screenUnderstanding","authorization":"denied","runtime":{"running":{}}}"#.utf8)
        let authorizedWaiting = Data(#"{"kind":"screenUnderstanding","authorization":"authorized","runtime":{"waitingForAuthorization":{}}}"#.utf8)
        let emptyPause = Data(#"{"kind":"screenUnderstanding","authorization":"authorized","runtime":{"paused":{"reasons":[],"resumeState":{"running":{}}}}}"#.utf8)

        #expect(throws: CollectorState.ValidationError.runtimeConflictsWithAuthorization) {
            try JSONDecoder().decode(CollectorState.self, from: deniedRunning)
        }
        #expect(throws: CollectorState.ValidationError.runtimeConflictsWithAuthorization) {
            try JSONDecoder().decode(CollectorState.self, from: authorizedWaiting)
        }
        #expect(throws: CollectorState.ValidationError.emptyPauseReasons) {
            try JSONDecoder().decode(CollectorState.self, from: emptyPause)
        }
    }

    @Test
    func publicReconstructionValidatesPersistedRuntimeShape() throws {
        let state = try CollectorState(
            kind: .weather,
            authorization: .authorized,
            runtime: .degraded(.dependencyUnavailable)
        )
        #expect(state.runtime == .degraded(.dependencyUnavailable))

        #expect(throws: CollectorState.ValidationError.runtimeConflictsWithAuthorization) {
            try CollectorState(
                kind: .weather,
                authorization: .denied,
                runtime: .running
            )
        }
        #expect(throws: CollectorState.ValidationError.emptyPauseReasons) {
            try CollectorState(
                kind: .weather,
                authorization: .authorized,
                runtime: .paused(reasons: [], resumeState: .running)
            )
        }
    }

    @Test
    func hardPauseOnlyEndsAnActuallyActiveSessionOnce() throws {
        let waiting = try CollectorStateMachine.transition(
            .configure,
            from: CollectorState(kind: .screenUnderstanding, authorization: .denied)
        ).current
        let waitingPause = try CollectorStateMachine.transition(
            .pause(.screenLocked),
            from: waiting
        )
        #expect(!waitingPause.requiresSessionBoundary)

        let running = try configuredCollector(kind: .screenUnderstanding)
        let firstPause = try CollectorStateMachine.transition(
            .pause(.screenLocked),
            from: running
        )
        let duplicatePause = try CollectorStateMachine.transition(
            .pause(.screenLocked),
            from: firstPause.current
        )
        #expect(firstPause.requiresSessionBoundary)
        #expect(!duplicatePause.requiresSessionBoundary)
    }

    private func configuredCollector(kind: CollectorKind) throws -> CollectorState {
        let initial = CollectorState(kind: kind, authorization: .authorized)
        return try CollectorStateMachine.transition(.configure, from: initial).current
    }
}
