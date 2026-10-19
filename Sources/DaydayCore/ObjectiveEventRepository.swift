import Foundation

public enum ObjectiveEventInsertResult: Equatable, Hashable, Sendable {
    case inserted
    case alreadyPresent
}

/// Persistence boundary for the closed, privacy-reviewed objective event envelope.
///
/// The range is half-open and selects events by `occurredAt`. Implementations
/// must reject empty, reversed, or non-finite ranges.
public protocol ObjectiveEventRepository: Sendable {
    func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult

    func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent]
}

/// Stable boundary immediately after a descending page of objective facts.
/// It contains only values already present on the objective-event envelope;
/// it does not add any new user data to persistence.
public struct ObjectiveEventPageCursor: Equatable, Hashable, Sendable {
    public let occurredAt: Date
    public let eventID: EventID

    public init(occurredAt: Date, eventID: EventID) {
        self.occurredAt = occurredAt
        self.eventID = eventID
    }
}

/// A newest-first page of objective facts. `nextCursor` is non-nil only when
/// an older page is available in the same requested range.
public struct ObjectiveEventPage: Equatable, Sendable {
    public let events: [ObjectiveEvent]
    public let nextCursor: ObjectiveEventPageCursor?

    public init(events: [ObjectiveEvent], nextCursor: ObjectiveEventPageCursor?) {
        self.events = events
        self.nextCursor = nextCursor
    }
}

/// Optional read capability for presentations that must not load an entire
/// busy workday before drawing their first screen.
public protocol ObjectiveEventPageRepository: ObjectiveEventRepository {
    /// Returns at most `limit` events ordered newest first. A cursor resumes
    /// strictly before the preceding page's final event.
    func fetchPage(
        occurredIn range: Range<Date>,
        before cursor: ObjectiveEventPageCursor?,
        limit: Int
    ) async throws -> ObjectiveEventPage
}
