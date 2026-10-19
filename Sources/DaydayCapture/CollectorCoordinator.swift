import DaydayCore
import Foundation

/// An immutable, presentation-safe view of every collector known to the application.
///
/// The snapshot contains only state-machine facts. It does not infer productivity, focus, user
/// presence, or that an external service performed work beyond the runtime state it reported.
public struct CollectorCoordinatorSnapshot: Equatable, Sendable {
    /// Exactly one state for every ``CollectorKind``, in `CollectorKind.allCases` order.
    public let collectors: [CollectorState]

    /// Application-wide suppression reasons currently owned by the coordinator.
    ///
    /// Collector-scoped reasons such as secure input and privacy exclusions remain visible on the
    /// affected collector state and are intentionally absent here.
    public let activeApplicationPauseReasons: Set<CollectionPauseReason>

    public var configuredCollectors: [CollectorState] {
        collectors.filter { $0.runtime != .unconfigured }
    }

    public var isApplicationPaused: Bool {
        !activeApplicationPauseReasons.isEmpty
    }

    public func state(for kind: CollectorKind) -> CollectorState {
        guard let state = collectors.first(where: { $0.kind == kind }) else {
            preconditionFailure("CollectorCoordinatorSnapshot must contain every CollectorKind")
        }
        return state
    }
}

/// The committed result of one coordinator transaction.
public struct CollectorCoordinatorTransition: Equatable, Sendable {
    public let previous: CollectorCoordinatorSnapshot
    public let current: CollectorCoordinatorSnapshot

    /// Kinds whose observable state actually changed. Empty means an idempotent no-op.
    public let changedKinds: [CollectorKind]

    /// Kinds for which this transaction introduced a hard Session boundary.
    public let sessionBoundaryKinds: [CollectorKind]

    public var requiresSessionBoundary: Bool {
        !sessionBoundaryKinds.isEmpty
    }
}

public enum CollectorCoordinatorError: Error, Equatable, Sendable {
    /// Application-wide lifecycle reasons must go through the broadcast API so one collector
    /// cannot drift away from the application state.
    case applicationWideReasonRequiresBroadcast(CollectionPauseReason)

    /// The state-machine rejected one action. The complete transaction remains uncommitted.
    case transitionRejected(
        kind: CollectorKind,
        reason: CollectorStateTransitionError
    )
}

/// In-memory application coordinator for collector consent and runtime facts.
///
/// This value owns no platform services and performs no I/O. Callers serialize mutation (for
/// example by keeping it on `@MainActor`). Batch and lifecycle operations first validate every
/// candidate transition and only then replace the committed state, preventing partial updates.
public struct CollectorCoordinator: Sendable {
    private static let applicationWideReasons: Set<CollectionPauseReason> = [
        .globalUserPause,
        .userSessionInactive,
        .screensAsleep,
        .screenLocked,
        .systemSleep,
    ]

    private var states: [CollectorKind: CollectorState]
    private var activeApplicationPauseReasons: Set<CollectionPauseReason> = []

    public init(authorizations: [CollectorKind: AuthorizationState] = [:]) {
        states = Dictionary(uniqueKeysWithValues: CollectorKind.allCases.map { kind in
            (kind, CollectorState(kind: kind, authorization: authorizations[kind] ?? .notDetermined))
        })
    }

    public var snapshot: CollectorCoordinatorSnapshot {
        makeSnapshot(states: states, pauseReasons: activeApplicationPauseReasons)
    }

    /// Applies one collector-scoped command.
    ///
    /// Repeating a command whose target state is already visible is a successful no-op. Invalid
    /// commands still fail without changing any state.
    @discardableResult
    public mutating func apply(
        _ action: CollectorStateAction,
        to kind: CollectorKind
    ) throws -> CollectorCoordinatorTransition {
        try apply([kind: action])
    }

    /// Atomically applies at most one command to each selected collector.
    ///
    /// This is useful when an application event updates several independent collectors. If any
    /// command is illegal, none of the otherwise-valid commands are committed.
    @discardableResult
    public mutating func apply(
        _ actions: [CollectorKind: CollectorStateAction]
    ) throws -> CollectorCoordinatorTransition {
        let previous = snapshot
        var candidates = states
        var boundaryKinds = Set<CollectorKind>()

        for kind in orderedKinds(in: actions.keys) {
            guard let action = actions[kind], let state = candidates[kind] else {
                preconditionFailure("Coordinator owns every CollectorKind")
            }
            if case let .pause(reason) = action,
               Self.applicationWideReasons.contains(reason) {
                throw CollectorCoordinatorError.applicationWideReasonRequiresBroadcast(reason)
            }
            if case let .resume(reason) = action,
               Self.applicationWideReasons.contains(reason) {
                throw CollectorCoordinatorError.applicationWideReasonRequiresBroadcast(reason)
            }

            do {
                let applied = try applyIdempotently(action, to: state)
                var current = applied.current

                // A collector configured while the app is paused must never become observably
                // active between transactions. These pauses are part of the same atomic command.
                if action == .configure {
                    for reason in orderedPauseReasons(activeApplicationPauseReasons) {
                        current = try CollectorStateMachine.transition(
                            .pause(reason),
                            from: current
                        ).current
                    }
                } else if applied.requiresSessionBoundary {
                    boundaryKinds.insert(kind)
                }

                candidates[kind] = current
            } catch let reason as CollectorStateTransitionError {
                throw CollectorCoordinatorError.transitionRejected(kind: kind, reason: reason)
            }
        }

        states = candidates
        return makeTransition(previous: previous, boundaryKinds: boundaryKinds)
    }

    @discardableResult
    public mutating func setGlobalPause(_ active: Bool) throws -> CollectorCoordinatorTransition {
        try setApplicationPause(.globalUserPause, active: active)
    }

    @discardableResult
    public mutating func setScreenLocked(_ locked: Bool) throws -> CollectorCoordinatorTransition {
        try setApplicationPause(.screenLocked, active: locked)
    }

    @discardableResult
    public mutating func setUserSessionActive(
        _ active: Bool
    ) throws -> CollectorCoordinatorTransition {
        try setApplicationPause(.userSessionInactive, active: !active)
    }

    @discardableResult
    public mutating func setScreensAwake(
        _ awake: Bool
    ) throws -> CollectorCoordinatorTransition {
        try setApplicationPause(.screensAsleep, active: !awake)
    }

    @discardableResult
    public mutating func setSystemSleeping(
        _ sleeping: Bool
    ) throws -> CollectorCoordinatorTransition {
        try setApplicationPause(.systemSleep, active: sleeping)
    }

    private mutating func setApplicationPause(
        _ reason: CollectionPauseReason,
        active: Bool
    ) throws -> CollectorCoordinatorTransition {
        precondition(Self.applicationWideReasons.contains(reason))
        let previous = snapshot
        let isAlreadyActive = activeApplicationPauseReasons.contains(reason)
        guard isAlreadyActive != active else {
            return makeTransition(previous: previous, boundaryKinds: [])
        }

        var candidates = states
        var boundaryKinds = Set<CollectorKind>()

        for kind in CollectorKind.allCases {
            guard let state = candidates[kind] else {
                preconditionFailure("Coordinator owns every CollectorKind")
            }
            guard state.runtime != .unconfigured else { continue }

            do {
                let transition = try CollectorStateMachine.transition(
                    active ? .pause(reason) : .resume(reason),
                    from: state
                )
                candidates[kind] = transition.current
                if transition.requiresSessionBoundary {
                    boundaryKinds.insert(kind)
                }
            } catch let transitionError as CollectorStateTransitionError {
                throw CollectorCoordinatorError.transitionRejected(
                    kind: kind,
                    reason: transitionError
                )
            }
        }

        // Commit both pieces of state only after every configured collector accepted the event.
        states = candidates
        if active {
            activeApplicationPauseReasons.insert(reason)
        } else {
            activeApplicationPauseReasons.remove(reason)
        }
        return makeTransition(previous: previous, boundaryKinds: boundaryKinds)
    }

    private struct AppliedAction {
        let current: CollectorState
        let requiresSessionBoundary: Bool
    }

    private func applyIdempotently(
        _ action: CollectorStateAction,
        to state: CollectorState
    ) throws -> AppliedAction {
        if actionAlreadyReflected(action, in: state) {
            return AppliedAction(
                current: state,
                requiresSessionBoundary: false
            )
        }
        let transition = try CollectorStateMachine.transition(action, from: state)
        return AppliedAction(
            current: transition.current,
            requiresSessionBoundary: transition.requiresSessionBoundary
        )
    }

    private func actionAlreadyReflected(
        _ action: CollectorStateAction,
        in state: CollectorState
    ) -> Bool {
        switch action {
        case .configure:
            return state.runtime != .unconfigured
        case .unconfigure:
            return state.runtime == .unconfigured
        case let .authorizationChanged(authorization):
            return state.authorization == authorization
        case let .pause(reason):
            guard case let .paused(reasons, _) = state.runtime else { return false }
            return reasons.contains(reason)
        case let .resume(reason):
            guard state.runtime != .unconfigured else { return false }
            guard case let .paused(reasons, _) = state.runtime else { return true }
            return !reasons.contains(reason)
        case let .degrade(reason):
            switch state.runtime {
            case .degraded(reason):
                return true
            case let .paused(_, resumeState):
                return resumeState == .degraded(reason)
            default:
                return false
            }
        case let .fail(reason):
            switch state.runtime {
            case .failed(reason):
                return true
            case let .paused(_, resumeState):
                return resumeState == .failed(reason)
            default:
                return false
            }
        case .recover:
            switch state.runtime {
            case .running, .waitingForAuthorization:
                return true
            case let .paused(_, resumeState):
                switch resumeState {
                case .running, .waitingForAuthorization:
                    return true
                case .degraded, .failed:
                    return false
                }
            case .unconfigured, .degraded, .failed:
                return false
            }
        }
    }

    private func makeTransition(
        previous: CollectorCoordinatorSnapshot,
        boundaryKinds: Set<CollectorKind>
    ) -> CollectorCoordinatorTransition {
        let current = snapshot
        let changedKinds = CollectorKind.allCases.filter {
            previous.state(for: $0) != current.state(for: $0)
        }
        return CollectorCoordinatorTransition(
            previous: previous,
            current: current,
            changedKinds: changedKinds,
            sessionBoundaryKinds: orderedKinds(in: boundaryKinds)
        )
    }

    private func makeSnapshot(
        states: [CollectorKind: CollectorState],
        pauseReasons: Set<CollectionPauseReason>
    ) -> CollectorCoordinatorSnapshot {
        CollectorCoordinatorSnapshot(
            collectors: CollectorKind.allCases.map { kind in
                guard let state = states[kind] else {
                    preconditionFailure("Coordinator owns every CollectorKind")
                }
                return state
            },
            activeApplicationPauseReasons: pauseReasons
        )
    }

    private func orderedKinds<S: Sequence>(in kinds: S) -> [CollectorKind]
    where S.Element == CollectorKind {
        let selected = Set(kinds)
        return CollectorKind.allCases.filter(selected.contains)
    }

    private func orderedPauseReasons(
        _ reasons: Set<CollectionPauseReason>
    ) -> [CollectionPauseReason] {
        CollectionPauseReason.allCases.filter(reasons.contains)
    }
}
