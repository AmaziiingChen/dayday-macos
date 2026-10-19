import DaydayCore
import Foundation

/// The output of a deterministic, read-only understanding pass.
///
/// Sessions retain only objective-event membership. Activities are deliberately
/// separate rule interpretations: they use a low confidence band and require
/// review, rather than presenting a task conclusion as an objective fact.
public struct ObjectiveUnderstandingSnapshot: Equatable, Sendable {
  public let sessions: [Session]
  public let activities: [Activity]

  public init(sessions: [Session], activities: [Activity]) {
    self.sessions = sessions
    self.activities = activities
  }
}

/// Reads only accepted objective-event and linked-projection contracts.
/// It has no access to Journal, Mood, evidence media, OCR, or provider APIs.
public struct ObjectiveUnderstandingPipeline: Sendable {
  public enum DerivationError: Error, Equatable, Sendable {
    case invalidAsOf
    case invalidInactivityThreshold
    case invalidDerivationRevision
    case invalidPreviousSnapshot
  }

  private let repository: any ObjectiveLinkedRecordRepository
  private let producerVersion = "understanding-v1"
  private let inactivityThreshold: TimeInterval

  /// Input inactivity is an objective continuity limit, never an absence or focus inference.
  public init(
    repository: any ObjectiveLinkedRecordRepository,
    inactivityThreshold: TimeInterval = 15 * 60
  ) {
    self.repository = repository
    self.inactivityThreshold = inactivityThreshold
  }

  /// Rebuilds the workday facts known at `asOf`. Events at or after the
  /// effective upper bound are deliberately excluded from the snapshot.
  public func derive(
    day: DayDescriptor,
    asOf: Date,
    derivationRevision: UInt64 = 1,
    previousSnapshot: ObjectiveUnderstandingSnapshot? = nil
  ) async throws -> ObjectiveUnderstandingSnapshot {
    guard asOf.timeIntervalSinceReferenceDate.isFinite else { throw DerivationError.invalidAsOf }
    guard inactivityThreshold.isFinite, inactivityThreshold > 0 else {
      throw DerivationError.invalidInactivityThreshold
    }
    guard derivationRevision > 0 else { throw DerivationError.invalidDerivationRevision }
    guard Self.isValid(previousSnapshot: previousSnapshot, for: derivationRevision) else {
      throw DerivationError.invalidPreviousSnapshot
    }
    let upperBound = min(max(asOf, day.boundary.startsAt), day.boundary.endsAt)
    guard upperBound > day.boundary.startsAt else {
      return ObjectiveUnderstandingSnapshot(sessions: [], activities: [])
    }
    let range = day.boundary.startsAt..<upperBound
    let events = try await repository.fetch(occurredIn: range).sorted(by: Self.orderedEarlier)
    let contexts = try await applicationContexts(for: events)
    let sessions = try await makeSessions(
      events: events,
      contexts: contexts,
      range: range,
      derivationRevision: derivationRevision,
      previousSessions: previousSnapshot?.sessions ?? []
    )
    let activities = try makeActivities(
      from: sessions,
      contexts: contexts,
      derivationRevision: derivationRevision,
      previousActivities: previousSnapshot?.activities ?? []
    )
    return ObjectiveUnderstandingSnapshot(sessions: sessions, activities: activities)
  }

  /// Converts only derived Activities to the Core-owned report allowlist.
  /// No personal artifact can be supplied through this API.
  public func workReportContext(
    day: DayDescriptor,
    snapshot: ObjectiveUnderstandingSnapshot
  ) throws -> WorkReportContext {
    let activities = try snapshot.activities.map { activity in
      try WorkReportActivityContext(
        id: activity.id,
        startedAt: activity.startedAt,
        endedAt: activity.endedAt,
        title: activity.title,
        summary: activity.summary,
        detectedInteractionSeconds: 0
      )
    }
    return try WorkReportContext(day: day, activities: activities)
  }

  /// Projects admitted application/window changes into objective report spans without requiring
  /// a display identity. This is intentionally separate from H2 Session/Activity derivation.
  public func objectiveApplicationSegments(
    day: DayDescriptor,
    asOf: Date
  ) async throws -> [WorkReportObjectiveApplicationSegment] {
    guard asOf.timeIntervalSinceReferenceDate.isFinite else { throw DerivationError.invalidAsOf }
    let upperBound = min(max(asOf, day.boundary.startsAt), day.boundary.endsAt)
    guard upperBound > day.boundary.startsAt else { return [] }
    let range = day.boundary.startsAt..<upperBound
    let events = try await repository.fetch(occurredIn: range).sorted(by: Self.orderedEarlier)
    let contexts = try await applicationContexts(for: events)

    struct OpenSegment {
      let event: ObjectiveEvent
      let context: ApplicationContextRecord
    }
    var open: OpenSegment?
    var result: [WorkReportObjectiveApplicationSegment] = []

    func close(_ segment: OpenSegment, at end: Date) throws {
      guard end > segment.event.occurredAt else { return }
      result.append(
        try WorkReportObjectiveApplicationSegment(
          startedAt: segment.event.occurredAt,
          endedAt: end,
          applicationLabel: segment.context.displayLabelSnapshot,
          windowTitle: segment.context.windowTitleSnapshot,
          documentFilenameHint: segment.context.documentFilenameHint,
          objectiveEventIDs: [segment.event.id]
        ))
    }

    for event in events {
      switch event.securityDisposition {
      case .metadataOnly, .excluded:
        if let open { try close(open, at: event.occurredAt) }
        open = nil
        continue
      case .allowed:
        break
      }
      let isLifecycleBoundary = try await lifecycleBoundary(for: event) != nil
      if event.kind == .systemBoundary || isLifecycleBoundary {
        if let open { try close(open, at: event.occurredAt) }
        open = nil
        continue
      }
      guard event.kind == .applicationContextChanged else { continue }
      if let open { try close(open, at: event.occurredAt) }
      open = contexts[event.id].map { OpenSegment(event: event, context: $0) }
    }
    if let open { try close(open, at: upperBound) }
    return result
  }

  /// Exposes only the already-derived deterministic provisional Activities for durable H2 storage.
  /// The caller receives no model, Journal, Mood, OCR, or media input through this seam.
  public func activityBatch(
    day: DayDescriptor,
    snapshot: ObjectiveUnderstandingSnapshot,
    derivationRevision: UInt64 = 1
  ) throws -> ActivityDerivationBatch? {
    guard !snapshot.activities.isEmpty else { return nil }
    return try ActivityDerivationBatch(
      day: day,
      derivationRevision: derivationRevision,
      activities: snapshot.activities
    )
  }

  private func applicationContexts(for events: [ObjectiveEvent]) async throws
    -> [EventID: ApplicationContextRecord]
  {
    let eventIDs = events.compactMap { event -> EventID? in
      guard event.kind == .applicationContextChanged,
        event.securityDisposition == .allowed
      else { return nil }
      return event.id
    }
    if let batchRepository = repository as? any ObjectiveApplicationContextBatchFetching {
      return try await batchRepository.fetchApplicationContexts(for: eventIDs)
    }
    var records: [EventID: ApplicationContextRecord] = [:]
    for eventID in eventIDs {
      if let record = try await repository.fetchApplicationContext(for: eventID) {
        records[eventID] = record
      }
    }
    return records
  }

  private func makeSessions(
    events: [ObjectiveEvent], contexts: [EventID: ApplicationContextRecord],
    range: Range<Date>,
    derivationRevision: UInt64,
    previousSessions: [Session]
  ) async throws -> [Session] {
    var lanes: [SessionScope: OpenLane] = [:]
    var sessions: [Session] = []

    func close(_ scope: SessionScope, at end: Date, reason: SessionHardBoundaryReason?) throws {
      guard let lane = lanes.removeValue(forKey: scope), end > lane.startedAt else { return }
      sessions.append(
        try Session(
          id: Self.sessionID(
            scope: scope,
            eventIDs: lane.eventIDs,
            derivationRevision: derivationRevision
          ),
          scope: scope,
          startedAt: lane.startedAt,
          endedAt: end,
          endingHardBoundary: reason,
          objectiveEventIDs: lane.eventIDs,
          lineage: try SessionLineage(
            derivationRevision: derivationRevision,
            supersedesSessionID: Self.sessionPredecessor(
              scope: scope,
              startedAt: lane.startedAt,
              eventIDs: lane.eventIDs,
              previousSessions: previousSessions
            )?.id
          )
        ))
    }

    for event in events {
      switch event.securityDisposition {
      case .metadataOnly, .excluded:
        if let displayID = event.display?.id {
          try close(.display(displayID), at: event.occurredAt, reason: .privacySuppressed)
        } else {
          for scope in lanes.keys.sorted(by: Self.orderedScope) {
            try close(scope, at: event.occurredAt, reason: .privacySuppressed)
          }
        }
        continue
      case .allowed:
        break
      }
      if event.kind == .systemBoundary {
        // The envelope proves a lifecycle gap but does not encode a concrete
        // cause, so retain the split without manufacturing a false reason.
        for scope in lanes.keys.sorted(by: Self.orderedScope) {
          try close(scope, at: event.occurredAt, reason: nil)
        }
        continue
      }
      if let reason = try await lifecycleBoundary(for: event) {
        for scope in lanes.keys.sorted(by: Self.orderedScope) {
          try close(scope, at: event.occurredAt, reason: reason)
        }
        continue
      }

      guard event.securityDisposition == .allowed else { continue }
      let scope: SessionScope?
      if let displayID = event.display?.id {
        scope = .display(displayID)
      } else if event.kind == .applicationContextChanged, contexts[event.id] != nil {
        scope = .workspace
      } else {
        scope = nil
      }
      guard let scope else { continue }
      if event.kind == .applicationContextChanged {
        guard let context = contexts[event.id] else { continue }
        let contextKey = ApplicationContextKey(context)
        if var lane = lanes[scope],
          lane.contextKey == contextKey,
          event.occurredAt.timeIntervalSince(lane.lastObservedAt) <= inactivityThreshold
        {
          lane.eventIDs.append(event.id)
          lane.lastObservedAt = event.occurredAt
          lanes[scope] = lane
          continue
        }
        try close(scope, at: event.occurredAt, reason: nil)
        lanes[scope] = OpenLane(
          startedAt: event.occurredAt,
          lastObservedAt: event.occurredAt,
          eventIDs: [event.id],
          contextKey: contextKey
        )
        continue
      }
      if let lane = lanes[scope],
        event.occurredAt.timeIntervalSince(lane.lastObservedAt) > inactivityThreshold
      {
        try close(
          scope,
          at: min(event.occurredAt, lane.lastObservedAt.addingTimeInterval(inactivityThreshold)),
          reason: nil)
      }
      if lanes[scope] == nil {
        lanes[scope] = OpenLane(
          startedAt: event.occurredAt, lastObservedAt: event.occurredAt,
          eventIDs: [event.id], contextKey: nil)
      } else {
        lanes[scope]?.eventIDs.append(event.id)
        lanes[scope]?.lastObservedAt = event.occurredAt
      }
    }

    for scope in lanes.keys.sorted(by: Self.orderedScope) {
      try close(scope, at: range.upperBound, reason: nil)
    }
    return sessions.sorted(by: Self.orderedEarlier)
  }

  private func lifecycleBoundary(for event: ObjectiveEvent) async throws
    -> SessionHardBoundaryReason?
  {
    guard event.kind == .collectorStateTransition,
      let state = try await repository.fetchCollectorState(for: event.id)
    else { return nil }
    if !state.state.authorization.permitsCollection { return .authorizationLost }
    guard case .paused(let reasons, _) = state.state.runtime else { return nil }
    if reasons.contains(.screenLocked) { return .screenLocked }
    if reasons.contains(.systemSleep) || reasons.contains(.screensAsleep) { return .systemSleep }
    if reasons.contains(.userSessionInactive) { return .userSessionLost }
    return .collectionPaused
  }

  private func makeActivities(
    from sessions: [Session],
    contexts: [EventID: ApplicationContextRecord],
    derivationRevision: UInt64,
    previousActivities: [Activity]
  ) throws -> [Activity] {
    struct Group {
      let applicationLabel: String
      var sessions: [Session]
    }

    var groups: [Group] = []
    for session in sessions {
      let labels = session.objectiveEventIDs.compactMap { contexts[$0]?.displayLabelSnapshot }
      let applicationLabel = labels.first ?? "应用"
      if var group = groups.last,
        group.applicationLabel == applicationLabel,
        group.sessions.last?.endingHardBoundary == nil,
        let priorEnd = group.sessions.last?.endedAt,
        session.startedAt == priorEnd
      {
        group.sessions.append(session)
        groups[groups.count - 1] = group
      } else {
        groups.append(
          Group(
            applicationLabel: applicationLabel,
            sessions: [session]
          ))
      }
    }

    return try groups.map { group in
      let first = group.sessions[0]
      let last = group.sessions[group.sessions.count - 1]
      let title = group.applicationLabel == "应用" ? "应用活动" : "使用 \(group.applicationLabel)"
      return try Activity(
        id: Self.activityID(
          sessionIDs: group.sessions.map(\.id), derivationRevision: derivationRevision),
        startedAt: first.startedAt,
        endedAt: last.endedAt,
        sessionIDs: group.sessions.map(\.id),
        title: title,
        confidence: .low,
        reviewState: .needsReview,
        interpretation: try ActivityInterpretation(
          origin: .deterministicRule,
          producerVersion: producerVersion,
          rationale: "由隐私边界内同一应用的连续客观 Session 归集。"
        ),
        lineage: try ActivityLineage(
          revision: derivationRevision,
          supersedesDeterministicRebuildActivityID: Self.activityPredecessor(
            for: group.sessions,
            previousActivities: previousActivities
          )?.id
        )
      )
    }
  }

  private struct OpenLane {
    let startedAt: Date
    var lastObservedAt: Date
    var eventIDs: [EventID]
    let contextKey: ApplicationContextKey?
  }

  private struct ApplicationContextKey: Equatable {
    let application: ApplicationIdentifier
    let windowTitle: String?
    let documentFilenameHint: String?

    init(_ context: ApplicationContextRecord) {
      application = context.applicationIdentifier
      windowTitle = context.windowTitleSnapshot
      documentFilenameHint = context.documentFilenameHint
    }
  }

  private static func orderedEarlier(_ lhs: ObjectiveEvent, _ rhs: ObjectiveEvent) -> Bool {
    lhs.occurredAt == rhs.occurredAt
      ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
      : lhs.occurredAt < rhs.occurredAt
  }

  private static func orderedEarlier(_ lhs: Session, _ rhs: Session) -> Bool {
    guard lhs.startedAt == rhs.startedAt else { return lhs.startedAt < rhs.startedAt }
    guard lhs.scope != rhs.scope else {
      return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
    return orderedScope(lhs.scope, rhs.scope)
  }

  private static func orderedScope(_ lhs: SessionScope, _ rhs: SessionScope) -> Bool {
    scopeKey(lhs) < scopeKey(rhs)
  }

  private static func scopeKey(_ scope: SessionScope) -> String {
    switch scope {
    case .workspace: return "0-workspace"
    case .display(let displayID): return "1-\(displayID.rawValue.uuidString)"
    }
  }

  private static func orderedDisplayID(_ lhs: DisplayID, _ rhs: DisplayID) -> Bool {
    lhs.rawValue.uuidString < rhs.rawValue.uuidString
  }

  private static func sessionID(
    scope: SessionScope,
    eventIDs: [EventID],
    derivationRevision: UInt64
  ) -> SessionID {
    SessionID(
      rawValue: deterministicUUID(
        namespace: "session",
        values: [String(derivationRevision), scopeKey(scope)]
          + eventIDs.map { $0.rawValue.uuidString }
      ))
  }

  private static func activityID(sessionIDs: [SessionID], derivationRevision: UInt64) -> ActivityID
  {
    ActivityID(
      rawValue: deterministicUUID(
        namespace: "activity",
        values: [String(derivationRevision)] + sessionIDs.map { $0.rawValue.uuidString }
      ))
  }

  private static func isValid(
    previousSnapshot: ObjectiveUnderstandingSnapshot?,
    for derivationRevision: UInt64
  ) -> Bool {
    guard derivationRevision > 1 else { return previousSnapshot == nil }
    guard let previousSnapshot, !previousSnapshot.sessions.isEmpty,
      !previousSnapshot.activities.isEmpty
    else { return false }
    let previousRevision = derivationRevision - 1
    return previousSnapshot.sessions.allSatisfy {
      $0.lineage.derivationRevision == previousRevision
    }
      && previousSnapshot.activities.allSatisfy {
        $0.lineage.revision == previousRevision
      }
  }

  private static func sessionPredecessor(
    scope: SessionScope,
    startedAt: Date,
    eventIDs: [EventID],
    previousSessions: [Session]
  ) -> Session? {
    let matches = previousSessions.filter {
      $0.scope == scope
        && $0.startedAt == startedAt
        && eventIDs.starts(with: $0.objectiveEventIDs)
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func activityPredecessor(
    for sessions: [Session],
    previousActivities: [Activity]
  ) -> Activity? {
    let previousSessionIDs = sessions.compactMap(\.lineage.supersedesSessionID)
    guard previousSessionIDs.count == sessions.count else { return nil }
    let matches = previousActivities.filter { $0.sessionIDs == previousSessionIDs }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func deterministicUUID(namespace: String, values: [String]) -> UUID {
    func fnv1a(_ seed: UInt64, _ value: String) -> UInt64 {
      value.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    let joined = ([namespace] + values).joined(separator: "|")
    let first = fnv1a(14_695_981_039_346_656_037, joined)
    let second = fnv1a(10_995_116_282_11, joined)
    let raw = String(format: "%016llx%016llx", first, second)
    return UUID(
      uuidString:
        "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
    )!
  }
}
