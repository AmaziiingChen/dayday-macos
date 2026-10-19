import Foundation

// MARK: - Work-safe identifiers

public struct ActivityID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public struct WorkNoteID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public struct WorkCalendarItemID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public struct WorkReminderItemID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public struct TodoItemID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

public struct EvidenceFrameID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

// MARK: - Explicit work-data allowlist

public struct WorkReportActivityContext: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteDate
    case invalidInterval
    case emptyTitle
    case invalidDetectedInteractionSeconds(Double)
  }

  public let id: ActivityID
  public let startedAt: Date
  public let endedAt: Date
  public let title: String
  public let summary: String?
  public let detectedInteractionSeconds: Double
  public let evidenceFrameIDs: [EvidenceFrameID]
  /// IDs of derived visible-content observations quoted by this activity summary.
  /// These references retain provenance only; observation bodies remain in the local archive.
  public let visibleContentObservationIDs: [VisibleContentObservationID]

  public init(
    id: ActivityID,
    startedAt: Date,
    endedAt: Date,
    title: String,
    summary: String? = nil,
    detectedInteractionSeconds: Double,
    evidenceFrameIDs: [EvidenceFrameID] = [],
    visibleContentObservationIDs: [VisibleContentObservationID] = []
  ) throws {
    guard startedAt.contextFinite, endedAt.contextFinite else {
      throw ValidationError.nonFiniteDate
    }
    guard startedAt < endedAt else {
      throw ValidationError.invalidInterval
    }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyTitle
    }
    let maximum = endedAt.timeIntervalSince(startedAt)
    guard detectedInteractionSeconds.isFinite,
      detectedInteractionSeconds >= 0,
      detectedInteractionSeconds <= maximum
    else {
      throw ValidationError.invalidDetectedInteractionSeconds(detectedInteractionSeconds)
    }

    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.title = title
    self.summary = summary
    self.detectedInteractionSeconds = detectedInteractionSeconds
    self.evidenceFrameIDs = evidenceFrameIDs
    self.visibleContentObservationIDs = visibleContentObservationIDs
  }
}

/// A bounded visual-model observation supplied to the text-only report model as an explicitly
/// uncertain sibling of objective activities. It is never reclassified as an Activity.
public struct WorkReportVisualSegmentContext: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteDate
    case invalidInterval
    case noObservationReferences
  }

  public let startedAt: Date
  public let endedAt: Date
  public let segment: VisualWorkSegment
  public let observationIDs: [VisibleContentObservationID]

  public init(
    startedAt: Date,
    endedAt: Date,
    segment: VisualWorkSegment,
    observationIDs: [VisibleContentObservationID]
  ) throws {
    guard startedAt.contextFinite, endedAt.contextFinite else {
      throw ValidationError.nonFiniteDate
    }
    guard startedAt < endedAt else { throw ValidationError.invalidInterval }
    guard !observationIDs.isEmpty else { throw ValidationError.noObservationReferences }
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.segment = segment
    self.observationIDs = observationIDs
  }
}

/// A deterministic report projection of admitted application/window context events.
///
/// This is objective H1 lineage, not a semantic H2 `Activity`: it deliberately remains usable
/// when legacy application events do not carry a display identity. Window labels are retained as
/// admitted by the application-context collector; the report pipeline does not apply a second
/// content filter to names or conversation labels.
public struct WorkReportObjectiveApplicationSegment: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteDate
    case invalidInterval
    case emptyApplicationLabel
    case applicationLabelTooLong
    case invalidWindowTitle
    case invalidDocumentFilenameHint
    case noObjectiveEventReferences
    case duplicateObjectiveEvent(EventID)
  }

  public let startedAt: Date
  public let endedAt: Date
  public let applicationLabel: String
  public let windowTitle: String?
  public let documentFilenameHint: String?
  public let objectiveEventIDs: [EventID]

  public init(
    startedAt: Date,
    endedAt: Date,
    applicationLabel: String,
    windowTitle: String? = nil,
    documentFilenameHint: String? = nil,
    objectiveEventIDs: [EventID]
  ) throws {
    guard startedAt.contextFinite, endedAt.contextFinite else {
      throw ValidationError.nonFiniteDate
    }
    guard startedAt < endedAt else { throw ValidationError.invalidInterval }
    guard Self.validText(applicationLabel, maximumUTF8Bytes: 96) else {
      if applicationLabel.utf8.count > 96 { throw ValidationError.applicationLabelTooLong }
      throw ValidationError.emptyApplicationLabel
    }
    if let windowTitle,
      !Self.validText(windowTitle, maximumUTF8Bytes: 256)
    {
      throw ValidationError.invalidWindowTitle
    }
    if let documentFilenameHint,
      !Self.validText(documentFilenameHint, maximumUTF8Bytes: 128)
    {
      throw ValidationError.invalidDocumentFilenameHint
    }
    guard !objectiveEventIDs.isEmpty else {
      throw ValidationError.noObjectiveEventReferences
    }
    if let duplicate = Self.firstDuplicate(objectiveEventIDs) {
      throw ValidationError.duplicateObjectiveEvent(duplicate)
    }
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.applicationLabel = applicationLabel
    self.windowTitle = windowTitle
    self.documentFilenameHint = documentFilenameHint
    self.objectiveEventIDs = objectiveEventIDs
  }

  private static func firstDuplicate<Value: Hashable>(_ values: [Value]) -> Value? {
    var seen = Set<Value>()
    return values.first { !seen.insert($0).inserted }
  }

  private static func validText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= maximumUTF8Bytes
      && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }
}

public struct WorkReportNoteContext: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteCreationDate
  }

  public let id: WorkNoteID
  public let createdAt: Date
  public let body: String
  public let activityID: ActivityID?

  public init(
    id: WorkNoteID,
    createdAt: Date,
    body: String,
    activityID: ActivityID? = nil
  ) throws {
    guard createdAt.contextFinite else {
      throw ValidationError.nonFiniteCreationDate
    }
    self.id = id
    self.createdAt = createdAt
    self.body = body
    self.activityID = activityID
  }
}

public struct AllowedWorkCalendarItem: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteDate
    case invalidInterval
    case emptyTitle
  }

  public let id: WorkCalendarItemID
  public let title: String
  public let startsAt: Date
  public let endsAt: Date
  public let isAllDay: Bool

  public init(
    id: WorkCalendarItemID,
    title: String,
    startsAt: Date,
    endsAt: Date,
    isAllDay: Bool
  ) throws {
    guard startsAt.contextFinite, endsAt.contextFinite else {
      throw ValidationError.nonFiniteDate
    }
    guard startsAt < endsAt else {
      throw ValidationError.invalidInterval
    }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyTitle
    }
    self.id = id
    self.title = title
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.isAllDay = isAllDay
  }
}

public struct AllowedWorkReminder: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case nonFiniteDate
  }

  public let id: WorkReminderItemID
  public let title: String
  public let dueAt: Date?
  public let completedAt: Date?

  public init(
    id: WorkReminderItemID,
    title: String,
    dueAt: Date? = nil,
    completedAt: Date? = nil
  ) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyTitle
    }
    guard [dueAt, completedAt].compactMap({ $0 }).allSatisfy(\.contextFinite) else {
      throw ValidationError.nonFiniteDate
    }
    self.id = id
    self.title = title
    self.dueAt = dueAt
    self.completedAt = completedAt
  }
}

public enum ConfirmedTodoState: String, Codable, Hashable, Sendable {
  case todo
  case done
  case cancelled
}

public struct ConfirmedTodoContext: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case nonFiniteDate
  }

  public let id: TodoItemID
  public let title: String
  public let state: ConfirmedTodoState
  public let dueAt: Date?
  public let completedAt: Date?
  public let activityID: ActivityID?

  public init(
    id: TodoItemID,
    title: String,
    state: ConfirmedTodoState,
    dueAt: Date? = nil,
    completedAt: Date? = nil,
    activityID: ActivityID? = nil
  ) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.emptyTitle
    }
    guard [dueAt, completedAt].compactMap({ $0 }).allSatisfy(\.contextFinite) else {
      throw ValidationError.nonFiniteDate
    }
    self.id = id
    self.title = title
    self.state = state
    self.dueAt = dueAt
    self.completedAt = completedAt
    self.activityID = activityID
  }
}

/// The only input envelope accepted by work-report generation and work-context exports.
/// Its stored properties are a closed allowlist of professional artifacts plus objective weather.
public struct WorkReportContext: Encodable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case weatherBelongsToDifferentDay(WeatherSnapshotID)
    case duplicateActivity(ActivityID)
    case duplicateWorkNote(WorkNoteID)
    case duplicateCalendarItem(WorkCalendarItemID)
    case duplicateReminder(WorkReminderItemID)
    case duplicateTodo(TodoItemID)
    case duplicateWeatherSnapshot(WeatherSnapshotID)
    case duplicateEvidenceFrame(EvidenceFrameID)
    case duplicateVisibleContentObservation(VisibleContentObservationID)
    case duplicateObjectiveEvent(EventID)
    case visualSegmentOutsideLogicalDay
    case objectiveApplicationSegmentOutsideLogicalDay
    case activityOutsideLogicalDay(ActivityID)
    case activityInteractionExceedsLogicalDayOverlap(ActivityID)
    case workNoteOutsideLogicalDay(WorkNoteID)
    case calendarItemDoesNotOverlapLogicalDay(WorkCalendarItemID)
    case reminderOutsideLogicalDay(WorkReminderItemID)
    case todoOutsideLogicalDay(TodoItemID)
    case weatherObservationOutsideLogicalDay(WeatherSnapshotID)
    case workNoteReferencesUnknownActivity(WorkNoteID, ActivityID)
    case todoReferencesUnknownActivity(TodoItemID, ActivityID)
  }

  public let day: DayDescriptor
  public let activities: [WorkReportActivityContext]
  /// Objective application/window spans that remain distinct from semantic Activities.
  public let objectiveApplicationSegments: [WorkReportObjectiveApplicationSegment]
  /// Model-derived screen understanding; independent from objective activities by design.
  public let visualSegments: [WorkReportVisualSegmentContext]
  public let workNotes: [WorkReportNoteContext]
  public let calendarItems: [AllowedWorkCalendarItem]
  public let reminders: [AllowedWorkReminder]
  public let confirmedTodos: [ConfirmedTodoContext]
  /// Objective environment only. No affective or causal interpretation is represented here.
  public let weatherSnapshots: [WeatherSnapshot]

  public init(
    day: DayDescriptor,
    activities: [WorkReportActivityContext] = [],
    objectiveApplicationSegments: [WorkReportObjectiveApplicationSegment] = [],
    visualSegments: [WorkReportVisualSegmentContext] = [],
    workNotes: [WorkReportNoteContext] = [],
    calendarItems: [AllowedWorkCalendarItem] = [],
    reminders: [AllowedWorkReminder] = [],
    confirmedTodos: [ConfirmedTodoContext] = [],
    weatherSnapshots: [WeatherSnapshot] = []
  ) throws {
    if let duplicate = Self.firstDuplicate(activities.map(\.id)) {
      throw ValidationError.duplicateActivity(duplicate)
    }
    if let duplicate = Self.firstDuplicate(
      objectiveApplicationSegments.flatMap(\.objectiveEventIDs)
    ) {
      throw ValidationError.duplicateObjectiveEvent(duplicate)
    }
    if let duplicate = Self.firstDuplicate(workNotes.map(\.id)) {
      throw ValidationError.duplicateWorkNote(duplicate)
    }
    if let duplicate = Self.firstDuplicate(calendarItems.map(\.id)) {
      throw ValidationError.duplicateCalendarItem(duplicate)
    }
    if let duplicate = Self.firstDuplicate(reminders.map(\.id)) {
      throw ValidationError.duplicateReminder(duplicate)
    }
    if let duplicate = Self.firstDuplicate(confirmedTodos.map(\.id)) {
      throw ValidationError.duplicateTodo(duplicate)
    }
    if let duplicate = Self.firstDuplicate(weatherSnapshots.map(\.id)) {
      throw ValidationError.duplicateWeatherSnapshot(duplicate)
    }
    if let duplicate = Self.firstDuplicate(activities.flatMap(\.evidenceFrameIDs)) {
      throw ValidationError.duplicateEvidenceFrame(duplicate)
    }
    if let duplicate = Self.firstDuplicate(activities.flatMap(\.visibleContentObservationIDs)) {
      throw ValidationError.duplicateVisibleContentObservation(duplicate)
    }
    if let duplicate = Self.firstDuplicate(visualSegments.flatMap(\.observationIDs)) {
      throw ValidationError.duplicateVisibleContentObservation(duplicate)
    }
    if let duplicate = Self.firstDuplicate(
      activities.flatMap(\.visibleContentObservationIDs) + visualSegments.flatMap(\.observationIDs)
    ) {
      throw ValidationError.duplicateVisibleContentObservation(duplicate)
    }

    let dayStart = day.boundary.startsAt
    let dayEnd = day.boundary.endsAt
    let containsPoint: (Date) -> Bool = { date in
      date >= dayStart && date < dayEnd
    }
    let overlapsDay: (Date, Date) -> Bool = { start, end in
      start < dayEnd && end > dayStart
    }
    if let activity = activities.first(where: {
      !overlapsDay($0.startedAt, $0.endedAt)
    }) {
      throw ValidationError.activityOutsideLogicalDay(activity.id)
    }
    if visualSegments.contains(where: { !overlapsDay($0.startedAt, $0.endedAt) }) {
      throw ValidationError.visualSegmentOutsideLogicalDay
    }
    if objectiveApplicationSegments.contains(where: {
      !overlapsDay($0.startedAt, $0.endedAt)
    }) {
      throw ValidationError.objectiveApplicationSegmentOutsideLogicalDay
    }
    if let activity = activities.first(where: {
      let overlapStart = max($0.startedAt, dayStart)
      let overlapEnd = min($0.endedAt, dayEnd)
      return $0.detectedInteractionSeconds > overlapEnd.timeIntervalSince(overlapStart)
    }) {
      throw ValidationError.activityInteractionExceedsLogicalDayOverlap(activity.id)
    }
    if let note = workNotes.first(where: { !containsPoint($0.createdAt) }) {
      throw ValidationError.workNoteOutsideLogicalDay(note.id)
    }
    if let item = calendarItems.first(where: {
      !overlapsDay($0.startsAt, $0.endsAt)
    }) {
      throw ValidationError.calendarItemDoesNotOverlapLogicalDay(item.id)
    }
    if let reminder = reminders.first(where: {
      ![$0.dueAt, $0.completedAt].compactMap({ $0 }).allSatisfy(containsPoint)
    }) {
      throw ValidationError.reminderOutsideLogicalDay(reminder.id)
    }
    if let todo = confirmedTodos.first(where: {
      ![$0.dueAt, $0.completedAt].compactMap({ $0 }).allSatisfy(containsPoint)
    }) {
      throw ValidationError.todoOutsideLogicalDay(todo.id)
    }
    if let mismatch = weatherSnapshots.first(where: { $0.dayID != day.id }) {
      throw ValidationError.weatherBelongsToDifferentDay(mismatch.id)
    }
    if let weather = weatherSnapshots.first(where: { !containsPoint($0.observedAt) }) {
      throw ValidationError.weatherObservationOutsideLogicalDay(weather.id)
    }

    let activityIDs = Set(activities.map(\.id))
    if let note = workNotes.first(where: {
      guard let activityID = $0.activityID else { return false }
      return !activityIDs.contains(activityID)
    }), let activityID = note.activityID {
      throw ValidationError.workNoteReferencesUnknownActivity(note.id, activityID)
    }
    if let todo = confirmedTodos.first(where: {
      guard let activityID = $0.activityID else { return false }
      return !activityIDs.contains(activityID)
    }), let activityID = todo.activityID {
      throw ValidationError.todoReferencesUnknownActivity(todo.id, activityID)
    }
    self.day = day
    self.activities = activities
    self.objectiveApplicationSegments = objectiveApplicationSegments
    self.visualSegments = visualSegments
    self.workNotes = workNotes
    self.calendarItems = calendarItems
    self.reminders = reminders
    self.confirmedTodos = confirmedTodos
    self.weatherSnapshots = weatherSnapshots
  }

  public var sourceReferences: WorkReportSourceReferences {
    WorkReportSourceReferences(
      activityIDs: activities.map(\.id),
      objectiveEventIDs: objectiveApplicationSegments.flatMap(\.objectiveEventIDs),
      workNoteIDs: workNotes.map(\.id),
      calendarItemIDs: calendarItems.map(\.id),
      reminderIDs: reminders.map(\.id),
      todoItemIDs: confirmedTodos.map(\.id),
      weatherSnapshotIDs: weatherSnapshots.map(\.id),
      evidenceFrameIDs: activities.flatMap(\.evidenceFrameIDs),
      visibleContentObservationIDs: activities.flatMap(\.visibleContentObservationIDs)
        + visualSegments.flatMap(\.observationIDs)
    )
  }

  private static func firstDuplicate<Value: Hashable>(_ values: [Value]) -> Value? {
    var seen = Set<Value>()
    for value in values where !seen.insert(value).inserted {
      return value
    }
    return nil
  }
}

/// Audit-safe identifiers retained by a report revision; it contains no artifact bodies.
public struct WorkReportSourceReferences: Codable, Hashable, Sendable {
  public static let empty = WorkReportSourceReferences()

  public let activityIDs: [ActivityID]
  public let objectiveEventIDs: [EventID]
  public let workNoteIDs: [WorkNoteID]
  public let calendarItemIDs: [WorkCalendarItemID]
  public let reminderIDs: [WorkReminderItemID]
  public let todoItemIDs: [TodoItemID]
  public let weatherSnapshotIDs: [WeatherSnapshotID]
  public let evidenceFrameIDs: [EvidenceFrameID]
  public let visibleContentObservationIDs: [VisibleContentObservationID]

  public init(
    activityIDs: [ActivityID] = [],
    objectiveEventIDs: [EventID] = [],
    workNoteIDs: [WorkNoteID] = [],
    calendarItemIDs: [WorkCalendarItemID] = [],
    reminderIDs: [WorkReminderItemID] = [],
    todoItemIDs: [TodoItemID] = [],
    weatherSnapshotIDs: [WeatherSnapshotID] = [],
    evidenceFrameIDs: [EvidenceFrameID] = [],
    visibleContentObservationIDs: [VisibleContentObservationID] = []
  ) {
    self.activityIDs = activityIDs
    self.objectiveEventIDs = objectiveEventIDs
    self.workNoteIDs = workNoteIDs
    self.calendarItemIDs = calendarItemIDs
    self.reminderIDs = reminderIDs
    self.todoItemIDs = todoItemIDs
    self.weatherSnapshotIDs = weatherSnapshotIDs
    self.evidenceFrameIDs = evidenceFrameIDs
    self.visibleContentObservationIDs = visibleContentObservationIDs
  }

  private enum CodingKeys: String, CodingKey {
    case activityIDs
    case objectiveEventIDs
    case workNoteIDs
    case calendarItemIDs
    case reminderIDs
    case todoItemIDs
    case weatherSnapshotIDs
    case evidenceFrameIDs
    case visibleContentObservationIDs
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    activityIDs = try values.decode([ActivityID].self, forKey: .activityIDs)
    objectiveEventIDs =
      try values.decodeIfPresent([EventID].self, forKey: .objectiveEventIDs) ?? []
    workNoteIDs = try values.decode([WorkNoteID].self, forKey: .workNoteIDs)
    calendarItemIDs = try values.decode([WorkCalendarItemID].self, forKey: .calendarItemIDs)
    reminderIDs = try values.decode([WorkReminderItemID].self, forKey: .reminderIDs)
    todoItemIDs = try values.decode([TodoItemID].self, forKey: .todoItemIDs)
    weatherSnapshotIDs = try values.decode([WeatherSnapshotID].self, forKey: .weatherSnapshotIDs)
    evidenceFrameIDs = try values.decode([EvidenceFrameID].self, forKey: .evidenceFrameIDs)
    visibleContentObservationIDs =
      try values.decodeIfPresent(
        [VisibleContentObservationID].self,
        forKey: .visibleContentObservationIDs
      ) ?? []
  }
}

extension Date {
  fileprivate var contextFinite: Bool {
    timeIntervalSinceReferenceDate.isFinite
  }
}
