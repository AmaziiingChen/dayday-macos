import Foundation

/// The macOS permission, if any, that gates one collector after product consent.
public enum PlatformPermissionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case screenRecording
    case accessibility
    case inputMonitoring
    case calendar
    case reminders
}

public enum CollectorPermissionRequirement: Codable, Equatable, Hashable, Sendable {
    case notRequired
    case tcc(PlatformPermissionKind)
}

/// Stable, localization-independent disclosure content for first-run and Settings UI.
/// UI may localize the copy, but must preserve all three semantic fields.
public struct CollectorConsentDisclosure: Equatable, Hashable, Sendable {
    public let collector: CollectorKind
    public let purpose: String
    public let collectedSummary: String
    public let notCollectedSummary: String
    public let permissionRequirement: CollectorPermissionRequirement
}

public extension CollectorKind {
    var consentDisclosure: CollectorConsentDisclosure {
        switch self {
        case .screenUnderstanding:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Understand visible work context for the timeline and work report.",
                collectedSummary: "Ephemeral screen frames and privacy-filtered derived evidence.",
                notCollectedSummary: "Original-resolution frames are never persisted; excluded or secret screens are not analyzed.",
                permissionRequirement: .tcc(.screenRecording)
            )
        case .applicationWindowContext:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Record which application and privacy-filtered window context is active.",
                collectedSummary: "Application identity, safe window metadata, control role, display, and state changes.",
                notCollectedSummary: "Input-field contents, passwords, document bodies, and secure controls are not collected.",
                permissionRequirement: .tcc(.accessibility)
            )
        case .chromeContext:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Add the active Chrome page context to the work timeline.",
                collectedSummary: "Active tab title, normalized domain and path, navigation, switching, and audio state.",
                notCollectedSummary: "Incognito tabs, query strings, fragments, form values, page bodies, and login state are not collected.",
                permissionRequirement: .notRequired
            )
        case .keyboardAggregates:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Build long-term, objective keyboard activity totals, committed-character totals, and a physical-key heat map.",
                collectedSummary: "Unordered physical key-code counts and a text-free committed-character count by hour.",
                notCollectedSummary: "Typed text, key order, shortcuts, and per-key-per-application detail are never persisted.",
                permissionRequirement: .tcc(.inputMonitoring)
            )
        case .pointerAggregates:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Build objective click, scroll, distance, and coarse display heat-map statistics.",
                collectedSummary: "Hourly button totals, scroll totals, estimated distance, and normalized display-grid bins.",
                notCollectedSummary: "Exact pointer coordinates, event timestamps, and replayable trajectories are never persisted.",
                permissionRequirement: .tcc(.inputMonitoring)
            )
        case .calendar:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Show allowed calendar context beside the work timeline and report.",
                collectedSummary: "Read-only event timing and the minimum enabled agenda fields.",
                notCollectedSummary: "Dayday does not create, edit, delete, or silently share calendar events.",
                permissionRequirement: .tcc(.calendar)
            )
        case .reminders:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Show allowed reminders beside the work timeline and report.",
                collectedSummary: "Read-only reminder status, timing, and the minimum enabled fields.",
                notCollectedSummary: "Dayday does not create, edit, delete, or silently share reminders.",
                permissionRequirement: .tcc(.reminders)
            )
        case .weather:
            return CollectorConsentDisclosure(
                collector: self,
                purpose: "Add city-level weather as objective daily and journal context.",
                collectedSummary: "Weather for a user-selected city from the configured provider.",
                notCollectedSummary: "The default mode does not request location or store precise addresses or movement history.",
                permissionRequirement: .notRequired
            )
        }
    }
}

/// Product-level consent. It is intentionally separate from TCC authorization
/// and from the collector's operational runtime state.
public enum CollectorConsentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unconfirmed
    case enabled
    case disabled
    case paused
}

/// Evidence that one disclosure was confirmed through an explicit user action.
/// This is product consent metadata, not a macOS authorization result.
public struct UserConsentConfirmation: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidTimestamp
        case invalidDisclosureVersion
    }

    public let collector: CollectorKind
    public let confirmedAt: Date
    public let disclosureVersion: String

    public init(
        collector: CollectorKind,
        confirmedAt: Date,
        disclosureVersion: String
    ) throws {
        guard confirmedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ValidationError.invalidTimestamp
        }
        guard !disclosureVersion.isEmpty,
              disclosureVersion.utf8.count <= 64,
              disclosureVersion.utf8.allSatisfy({ byte in
                  byte.isASCIIAlphaNumeric || byte == 46 || byte == 43 || byte == 45 || byte == 95
              }) else {
            throw ValidationError.invalidDisclosureVersion
        }

        self.collector = collector
        self.confirmedAt = confirmedAt
        self.disclosureVersion = disclosureVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            collector: container.decode(CollectorKind.self, forKey: .collector),
            confirmedAt: container.decode(Date.self, forKey: .confirmedAt),
            disclosureVersion: container.decode(String.self, forKey: .disclosureVersion)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case collector
        case confirmedAt
        case disclosureVersion
    }
}

/// One collector's persisted product-consent decision.
public struct CollectorConsent: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case missingConfirmation
        case unexpectedConfirmation
        case confirmationCollectorMismatch
    }

    public let collector: CollectorKind
    public let status: CollectorConsentStatus
    public let confirmation: UserConsentConfirmation?

    /// New collectors are inert and cannot request TCC permission or collect.
    public init(collector: CollectorKind) {
        self.collector = collector
        self.status = .unconfirmed
        self.confirmation = nil
    }

    fileprivate init(
        collector: CollectorKind,
        status: CollectorConsentStatus,
        confirmation: UserConsentConfirmation?
    ) throws {
        switch status {
        case .unconfirmed:
            guard confirmation == nil else {
                throw ValidationError.unexpectedConfirmation
            }
        case .enabled, .disabled, .paused:
            guard let confirmation else {
                throw ValidationError.missingConfirmation
            }
            guard confirmation.collector == collector else {
                throw ValidationError.confirmationCollectorMismatch
            }
        }

        self.collector = collector
        self.status = status
        self.confirmation = confirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            collector: container.decode(CollectorKind.self, forKey: .collector),
            status: container.decode(CollectorConsentStatus.self, forKey: .status),
            confirmation: container.decodeIfPresent(
                UserConsentConfirmation.self,
                forKey: .confirmation
            )
        )
    }

    public var permitsPermissionRequest: Bool { status == .enabled }
    public var permitsCollection: Bool { status == .enabled }

    private enum CodingKeys: String, CodingKey {
        case collector
        case status
        case confirmation
    }
}

/// All consent-changing actions carry explicit user confirmation. There is no
/// launch, preflight, restore, migration, or remote-Agent action in this type.
public enum CollectorConsentAction: Equatable, Hashable, Sendable {
    case enable(UserConsentConfirmation)
    case disable(UserConsentConfirmation)
    case pause(UserConsentConfirmation)
    case resume(UserConsentConfirmation)
}

public enum CollectorConsentTransitionError: Error, Equatable, Sendable {
    case confirmationCollectorMismatch
    case alreadyInRequestedState(CollectorConsentStatus)
    case cannotPause(CollectorConsentStatus)
    case cannotResume(CollectorConsentStatus)
}

public enum CollectorConsentStateMachine {
    public static func transition(
        _ action: CollectorConsentAction,
        from previous: CollectorConsent
    ) throws -> CollectorConsent {
        let confirmation = action.confirmation
        guard confirmation.collector == previous.collector else {
            throw CollectorConsentTransitionError.confirmationCollectorMismatch
        }

        let nextStatus: CollectorConsentStatus
        switch action {
        case .enable:
            guard previous.status != .enabled else {
                throw CollectorConsentTransitionError.alreadyInRequestedState(.enabled)
            }
            nextStatus = .enabled
        case .disable:
            guard previous.status != .disabled else {
                throw CollectorConsentTransitionError.alreadyInRequestedState(.disabled)
            }
            nextStatus = .disabled
        case .pause:
            guard previous.status == .enabled else {
                throw CollectorConsentTransitionError.cannotPause(previous.status)
            }
            nextStatus = .paused
        case .resume:
            guard previous.status == .paused else {
                throw CollectorConsentTransitionError.cannotResume(previous.status)
            }
            nextStatus = .enabled
        }

        return try CollectorConsent(
            collector: previous.collector,
            status: nextStatus,
            confirmation: confirmation
        )
    }
}

private extension CollectorConsentAction {
    var confirmation: UserConsentConfirmation {
        switch self {
        case let .enable(confirmation),
             let .disable(confirmation),
             let .pause(confirmation),
             let .resume(confirmation):
            return confirmation
        }
    }
}

private extension UInt8 {
    var isASCIIAlphaNumeric: Bool {
        (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
    }
}
