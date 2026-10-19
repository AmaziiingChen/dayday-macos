import Foundation

/// A user-visible collector whose consent and runtime health are managed
/// independently from the other collectors.
public enum CollectorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case screenUnderstanding
    case applicationWindowContext
    case chromeContext
    case keyboardAggregates
    case pointerAggregates
    case calendar
    case reminders
    case weather
}

/// The most recent authorization fact known to the application.
///
/// Unknown and restricted states fail closed. `revoked` is distinct from an
/// initial denial so the UI can explain that a previously running collector
/// stopped without repeatedly prompting the user.
public enum AuthorizationState: String, Codable, CaseIterable, Hashable, Sendable {
    case notRequired
    case notDetermined
    case authorized
    case denied
    case restricted
    case revoked
    /// The app has a related capability, but not the read access this collector requires.
    case insufficientAccess
    case unknown

    public var permitsCollection: Bool {
        self == .notRequired || self == .authorized
    }
}

/// A reason collection is intentionally suppressed rather than unhealthy.
public enum CollectionPauseReason: String, Codable, CaseIterable, Hashable, Sendable {
    case globalUserPause
    /// The current GUI login session is not active on the console.
    case userSessionInactive
    /// The displays are asleep and therefore unavailable for objective observation.
    case screensAsleep
    /// Reserved for a separately validated, immediate lock-screen boundary.
    case screenLocked
    case systemSleep
    case secureInput
    case privacyExclusion

    /// Every current pause reason is a hard boundary for the affected
    /// collection stream. Most importantly, a global user pause, lock, or
    /// sleep, inactive GUI session, or sleeping displays can never be bridged
    /// by a Session.
    public var requiresSessionBoundary: Bool { true }
}

/// A collector can still emit a useful, privacy-safe subset of its contract.
public enum CollectorDegradationReason: String, Codable, CaseIterable, Hashable, Sendable {
    case partialCapability
    case dependencyUnavailable
    case unsupportedEnvironment
    case resourcePressure
}

/// A stable, non-sensitive failure category suitable for local diagnostics.
public enum CollectorFailureReason: String, Codable, CaseIterable, Hashable, Sendable {
    case initializationFailed
    case serviceUnavailable
    case invariantViolated
    case unexpectedTermination
}

/// The non-paused state to restore after every active pause reason clears.
public enum CollectorResumeState: Codable, Equatable, Hashable, Sendable {
    case waitingForAuthorization
    case running
    case degraded(CollectorDegradationReason)
    case failed(CollectorFailureReason)

    fileprivate var runtimeState: CollectorRuntimeState {
        switch self {
        case .waitingForAuthorization:
            return .waitingForAuthorization
        case .running:
            return .running
        case let .degraded(reason):
            return .degraded(reason)
        case let .failed(reason):
            return .failed(reason)
        }
    }
}

/// Operational state shown independently for each collector.
public enum CollectorRuntimeState: Codable, Equatable, Hashable, Sendable {
    case unconfigured
    case waitingForAuthorization
    case running
    case paused(reasons: Set<CollectionPauseReason>, resumeState: CollectorResumeState)
    case degraded(CollectorDegradationReason)
    case failed(CollectorFailureReason)

    fileprivate var resumeState: CollectorResumeState? {
        switch self {
        case .unconfigured:
            return nil
        case .waitingForAuthorization:
            return .waitingForAuthorization
        case .running:
            return .running
        case let .paused(_, resumeState):
            return resumeState
        case let .degraded(reason):
            return .degraded(reason)
        case let .failed(reason):
            return .failed(reason)
        }
    }
}

/// A valid snapshot of one collector's consent and runtime state.
public struct CollectorState: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyPauseReasons
        case runtimeConflictsWithAuthorization
    }

    public let kind: CollectorKind
    public let authorization: AuthorizationState
    public let runtime: CollectorRuntimeState

    /// New collectors are inert until an explicit configure transition.
    public init(kind: CollectorKind, authorization: AuthorizationState = .notDetermined) {
        self.kind = kind
        self.authorization = authorization
        self.runtime = .unconfigured
    }

    public init(
        kind: CollectorKind,
        authorization: AuthorizationState,
        runtime: CollectorRuntimeState
    ) throws {
        try Self.validate(authorization: authorization, runtime: runtime)
        self.kind = kind
        self.authorization = authorization
        self.runtime = runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CollectorKind.self, forKey: .kind)
        let authorization = try container.decode(AuthorizationState.self, forKey: .authorization)
        let runtime = try container.decode(CollectorRuntimeState.self, forKey: .runtime)
        try self.init(kind: kind, authorization: authorization, runtime: runtime)
    }

    private static func validate(
        authorization: AuthorizationState,
        runtime: CollectorRuntimeState
    ) throws {
        switch runtime {
        case .unconfigured, .failed:
            return
        case .waitingForAuthorization:
            guard !authorization.permitsCollection else {
                throw ValidationError.runtimeConflictsWithAuthorization
            }
        case .running, .degraded:
            guard authorization.permitsCollection else {
                throw ValidationError.runtimeConflictsWithAuthorization
            }
        case let .paused(reasons, resumeState):
            guard !reasons.isEmpty else {
                throw ValidationError.emptyPauseReasons
            }
            if authorization.permitsCollection {
                guard resumeState != .waitingForAuthorization else {
                    throw ValidationError.runtimeConflictsWithAuthorization
                }
            } else {
                guard resumeState == .waitingForAuthorization || resumeState.isFailed else {
                    throw ValidationError.runtimeConflictsWithAuthorization
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case authorization
        case runtime
    }
}

/// Inputs accepted by the pure collector state machine.
public enum CollectorStateAction: Equatable, Hashable, Sendable {
    case configure
    case unconfigure
    case authorizationChanged(AuthorizationState)
    case pause(CollectionPauseReason)
    case resume(CollectionPauseReason)
    case degrade(CollectorDegradationReason)
    case fail(CollectorFailureReason)
    case recover
}

public struct CollectorStateTransition: Equatable, Hashable, Sendable {
    public let previous: CollectorState
    public let current: CollectorState
    public let requiresSessionBoundary: Bool
}

public enum CollectorStateTransitionError: Error, Equatable, Sendable {
    case alreadyConfigured
    case notConfigured
    case pauseReasonNotActive(CollectionPauseReason)
    case cannotDegrade(CollectorRuntimeState)
    case cannotRecover(CollectorRuntimeState)
}

/// Pure transition policy shared by capture coordinators and presentation.
public enum CollectorStateMachine {
    public static func transition(
        _ action: CollectorStateAction,
        from previous: CollectorState
    ) throws -> CollectorStateTransition {
        let nextRuntime: CollectorRuntimeState
        var nextAuthorization = previous.authorization
        var requiresSessionBoundary = false

        switch action {
        case .configure:
            guard previous.runtime == .unconfigured else {
                throw CollectorStateTransitionError.alreadyConfigured
            }
            nextRuntime = activeRuntime(for: previous.authorization)

        case .unconfigure:
            guard previous.runtime != .unconfigured else {
                throw CollectorStateTransitionError.notConfigured
            }
            nextRuntime = .unconfigured

        case let .authorizationChanged(authorization):
            nextAuthorization = authorization
            nextRuntime = runtime(
                afterAuthorizationChangedTo: authorization,
                from: previous.runtime
            )
            requiresSessionBoundary = previous.authorization.permitsCollection
                && !authorization.permitsCollection
                && previous.runtime.hasActiveCollection

        case let .pause(reason):
            guard let resumeState = previous.runtime.resumeState else {
                throw CollectorStateTransitionError.notConfigured
            }

            var reasons: Set<CollectionPauseReason>
            if case let .paused(activeReasons, _) = previous.runtime {
                reasons = activeReasons
            } else {
                reasons = []
            }
            let inserted = reasons.insert(reason).inserted
            nextRuntime = .paused(reasons: reasons, resumeState: resumeState)
            requiresSessionBoundary = inserted
                && reason.requiresSessionBoundary
                && previous.runtime.hasActiveCollection

        case let .resume(reason):
            guard case let .paused(activeReasons, resumeState) = previous.runtime else {
                throw CollectorStateTransitionError.pauseReasonNotActive(reason)
            }
            guard activeReasons.contains(reason) else {
                throw CollectorStateTransitionError.pauseReasonNotActive(reason)
            }

            var remainingReasons = activeReasons
            remainingReasons.remove(reason)
            if remainingReasons.isEmpty {
                nextRuntime = resumedRuntime(
                    resumeState,
                    authorization: previous.authorization
                )
            } else {
                nextRuntime = .paused(
                    reasons: remainingReasons,
                    resumeState: resumeState
                )
            }

        case let .degrade(reason):
            switch previous.runtime {
            case .running, .degraded:
                nextRuntime = .degraded(reason)
            case let .paused(reasons, resumeState):
                guard resumeState != .waitingForAuthorization,
                      !resumeState.isFailed else {
                    throw CollectorStateTransitionError.cannotDegrade(previous.runtime)
                }
                nextRuntime = .paused(
                    reasons: reasons,
                    resumeState: .degraded(reason)
                )
            case .unconfigured, .waitingForAuthorization, .failed:
                throw CollectorStateTransitionError.cannotDegrade(previous.runtime)
            }

        case let .fail(reason):
            switch previous.runtime {
            case .unconfigured:
                throw CollectorStateTransitionError.notConfigured
            case let .paused(reasons, _):
                nextRuntime = .paused(
                    reasons: reasons,
                    resumeState: .failed(reason)
                )
            case .waitingForAuthorization, .running, .degraded, .failed:
                nextRuntime = .failed(reason)
            }

        case .recover:
            switch previous.runtime {
            case .degraded, .failed:
                nextRuntime = activeRuntime(for: previous.authorization)
            case let .paused(reasons, resumeState)
                where resumeState.isDegradedOrFailed:
                nextRuntime = .paused(
                    reasons: reasons,
                    resumeState: resumeTarget(for: previous.authorization)
                )
            case .unconfigured, .waitingForAuthorization, .running, .paused:
                throw CollectorStateTransitionError.cannotRecover(previous.runtime)
            }
        }

        let current = try CollectorState(
            kind: previous.kind,
            authorization: nextAuthorization,
            runtime: nextRuntime
        )
        return CollectorStateTransition(
            previous: previous,
            current: current,
            requiresSessionBoundary: requiresSessionBoundary
        )
    }

    private static func activeRuntime(for authorization: AuthorizationState) -> CollectorRuntimeState {
        resumeTarget(for: authorization).runtimeState
    }

    private static func resumeTarget(for authorization: AuthorizationState) -> CollectorResumeState {
        authorization.permitsCollection ? .running : .waitingForAuthorization
    }

    private static func resumedRuntime(
        _ resumeState: CollectorResumeState,
        authorization: AuthorizationState
    ) -> CollectorRuntimeState {
        guard authorization.permitsCollection else {
            return .waitingForAuthorization
        }
        return resumeState.runtimeState
    }

    private static func runtime(
        afterAuthorizationChangedTo authorization: AuthorizationState,
        from runtime: CollectorRuntimeState
    ) -> CollectorRuntimeState {
        switch runtime {
        case .unconfigured:
            return .unconfigured
        case .waitingForAuthorization:
            return activeRuntime(for: authorization)
        case .running:
            return activeRuntime(for: authorization)
        case let .degraded(reason):
            return authorization.permitsCollection
                ? .degraded(reason)
                : .waitingForAuthorization
        case let .failed(reason):
            return .failed(reason)
        case let .paused(reasons, resumeState):
            let nextResumeState: CollectorResumeState
            if authorization.permitsCollection {
                nextResumeState = resumeState == .waitingForAuthorization
                    ? .running
                    : resumeState
            } else if resumeState.isFailed {
                nextResumeState = resumeState
            } else {
                nextResumeState = .waitingForAuthorization
            }
            return .paused(reasons: reasons, resumeState: nextResumeState)
        }
    }
}

private extension CollectorRuntimeState {
    var hasActiveCollection: Bool {
        switch self {
        case .running, .degraded:
            return true
        case .unconfigured, .waitingForAuthorization, .paused, .failed:
            return false
        }
    }
}

private extension CollectorResumeState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isDegradedOrFailed: Bool {
        switch self {
        case .degraded, .failed:
            return true
        case .waitingForAuthorization, .running:
            return false
        }
    }
}
