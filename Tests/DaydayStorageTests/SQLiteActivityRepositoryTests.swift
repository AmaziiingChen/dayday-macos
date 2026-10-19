import CSQLite
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite activity repository", .serialized)
struct SQLiteActivityRepositoryTests {
  @Test("persisted Session activities replay exactly and query deterministically")
  func persistsQueriesAndReplays() async throws {
    try await withFixture { _, day, repository, sessions in
      let activities = try makeActivities(sessions: sessions)
      let batch = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: activities.reversed())

      #expect(try await repository.save(batch) == .inserted)
      #expect(try await repository.save(batch) == .alreadyPresent)
      #expect(
        try await repository.activities(startedIn: day.boundary.startsAt..<day.boundary.endsAt)
          == activities)
    }
  }

  @Test("subset mixed forged-day and changed-ID batches conflict without partial writes")
  func rejectsConflictingBatchesAtomically() async throws {
    try await withFixture { _, day, repository, sessions in
      let originalActivities = try makeActivities(sessions: sessions)
      let original = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: originalActivities)
      #expect(try await repository.save(original) == .inserted)
      let baseline = try await repository.activities(
        startedIn: day.boundary.startsAt..<day.boundary.endsAt)

      let subset = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: [originalActivities[0]])
      let newActivity = try makeActivity(
        id: ActivityID(), sessionIDs: [sessions[2].id], startedAt: sessions[2].startedAt,
        endedAt: sessions[2].endedAt)
      let mixed = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: [originalActivities[0], newActivity])
      let changed = try makeActivity(
        id: originalActivities[0].id, sessionIDs: originalActivities[0].sessionIDs,
        startedAt: originalActivities[0].startedAt, endedAt: originalActivities[0].endedAt,
        title: "Changed observed activity")
      let changedBatch = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: [changed, originalActivities[1]])
      let forgedDay = try makeDay(day: 2)
      let forged = try makeActivity(
        id: originalActivities[0].id, sessionIDs: [sessions[0].id],
        startedAt: forgedDay.boundary.startsAt.addingTimeInterval(60),
        endedAt: forgedDay.boundary.startsAt.addingTimeInterval(120))
      let forgedBatch = try ActivityDerivationBatch(
        day: forgedDay, derivationRevision: 1, activities: [forged])

      #expect(try await repository.save(subset) == .conflict)
      #expect(try await repository.save(mixed) == .conflict)
      #expect(try await repository.save(changedBatch) == .conflict)
      #expect(try await repository.save(forgedBatch) == .conflict)
      #expect(
        try await repository.activities(startedIn: day.boundary.startsAt..<day.boundary.endsAt)
          == baseline)
    }
  }

  @Test("tampered envelopes records membership and normalized columns fail closed")
  func rejectsTamperedStorage() async throws {
    for mutation in [
      "UPDATE h2_activity_batches SET activity_ids = 'forged'",
      "DELETE FROM h2_activity_records",
      "DELETE FROM h2_activity_membership",
      "UPDATE h2_activity_records SET started_at = started_at + 1",
      "UPDATE h2_activity_records SET payload = '{}'",
    ] {
      try await withFixture { url, day, repository, sessions in
        let activities = try makeActivities(sessions: sessions)
        let batch = try ActivityDerivationBatch(
          day: day, derivationRevision: 1, activities: activities)
        #expect(try await repository.save(batch) == .inserted)
        try execute(mutation, at: url)
        #expect(try await repository.save(batch) == .conflict)
      }
    }
  }

  @Test("invalid ranges and unrepresentable revisions fail closed")
  func rejectsInvalidRangeAndOverflow() async throws {
    try await withFixture { _, day, repository, sessions in
      await #expect(throws: ActivityStoreError.invalidRange) {
        _ = try await repository.activities(
          startedIn: day.boundary.startsAt..<day.boundary.startsAt)
      }
      let activity = try makeActivity(
        id: ActivityID(), sessionIDs: [sessions[0].id], startedAt: sessions[0].startedAt,
        endedAt: sessions[0].endedAt)
      let overflow = try Activity(
        id: activity.id, startedAt: activity.startedAt, endedAt: activity.endedAt,
        sessionIDs: activity.sessionIDs, evidenceReferences: [], title: activity.title,
        confidence: .low,
        reviewState: .needsReview, interpretation: activity.interpretation,
        lineage: try ActivityLineage(
          revision: UInt64.max, supersedesDeterministicRebuildActivityID: ActivityID())
      )
      let batch = try ActivityDerivationBatch(
        day: day, derivationRevision: UInt64.max, activities: [overflow])
      #expect(try await repository.save(batch) == .conflict)
    }
  }

  @Test("schema mutations fail closed and a clean reopen preserves records")
  func validatesSchemaAndReopens() async throws {
    try await withFixture { url, day, repository, sessions in
      let activities = try makeActivities(sessions: sessions)
      let batch = try ActivityDerivationBatch(
        day: day, derivationRevision: 1, activities: activities)
      #expect(try await repository.save(batch) == .inserted)
      let reopened = try SQLiteActivityRepository(location: .file(url))
      #expect(
        try await reopened.activities(startedIn: day.boundary.startsAt..<day.boundary.endsAt)
          == activities)
    }

    for mutation in [
      "DROP INDEX h2_activity_records_started_at",
      "CREATE TRIGGER h2_activity_extra AFTER INSERT ON h2_activity_records BEGIN SELECT 1; END",
      "ALTER TABLE h2_activity_records ADD COLUMN forged TEXT",
      "ALTER TABLE h2_activity_membership ADD COLUMN forged TEXT",
      "ALTER TABLE h2_activity_batches RENAME TO h2_activity_batches_renamed",
      "DROP TABLE h2_activity_batches; CREATE TABLE h2_activity_batches (batch_id TEXT PRIMARY KEY) STRICT",
    ] {
      try await withFixture { url, _, _, _ in
        try execute(mutation, at: url)
        #expect(throws: ActivityStoreError.self) {
          _ = try SQLiteActivityRepository(location: .file(url))
        }
      }
    }
  }

  @Test("twelve direct first opens are process-locally serialized")
  func concurrentDirectFirstOpen() async throws {
    for _ in 0..<10 {
      try await withTemporaryActivityDatabase { url in
        let gate = ActivityOpenGate(participantCount: 12)
        let repositories = try await withThrowingTaskGroup(
          of: SQLiteActivityRepository.self,
          returning: [SQLiteActivityRepository].self
        ) { group in
          for _ in 0..<12 {
            group.addTask {
              await gate.wait()
              return try SQLiteActivityRepository(location: .file(url))
            }
          }
          var values: [SQLiteActivityRepository] = []
          for try await value in group { values.append(value) }
          return values
        }
        #expect(repositories.count == 12)
      }
    }
  }

  private func makeActivities(sessions: [Session]) throws -> [Activity] {
    try [
      makeActivity(
        id: ActivityID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
        sessionIDs: [sessions[0].id], startedAt: sessions[0].startedAt, endedAt: sessions[0].endedAt
      ),
      makeActivity(
        id: ActivityID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!),
        sessionIDs: [sessions[1].id], startedAt: sessions[1].startedAt, endedAt: sessions[1].endedAt
      ),
    ]
  }

  private func makeActivity(
    id: ActivityID, sessionIDs: [SessionID], startedAt: Date, endedAt: Date,
    title: String = "Observed activity"
  ) throws -> Activity {
    try Activity(
      id: id, startedAt: startedAt, endedAt: endedAt, sessionIDs: sessionIDs,
      evidenceReferences: [], title: title, confidence: .low, reviewState: .needsReview,
      interpretation: try ActivityInterpretation(
        origin: .deterministicRule, producerVersion: "rule-v1"))
  }

  private func makeDay(day: Int = 1) throws -> DayDescriptor {
    let start = Date(timeIntervalSince1970: 1_704_081_600 + TimeInterval(day - 1) * 86_400)
    return try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: day), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400)))
  }
}

private actor ActivityOpenGate {
  private let participantCount: Int
  private var arrivals = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []
  init(participantCount: Int) { self.participantCount = participantCount }
  func wait() async {
    arrivals += 1
    guard arrivals < participantCount else {
      let waiting = continuations
      continuations.removeAll()
      for continuation in waiting { continuation.resume() }
      return
    }
    await withCheckedContinuation { continuations.append($0) }
  }
}

private func withFixture(
  _ body: (URL, DayDescriptor, SQLiteActivityRepository, [Session]) async throws -> Void
) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-activity-\(UUID().uuidString).sqlite")
  defer {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
  let day = try DayDescriptor(
    logicalDate: .init(year: 2024, month: 1, day: 1), timeZoneIdentifier: "UTC",
    boundary: .init(
      hour: 4, startsAt: Date(timeIntervalSince1970: 1_704_081_600),
      endsAt: Date(timeIntervalSince1970: 1_704_168_000)))
  let objective = try SQLiteObjectiveEventRepository(location: .file(url))
  var sessions: [Session] = []
  for index in 0..<3 {
    let date = day.boundary.startsAt.addingTimeInterval(TimeInterval(60 + index * 120))
    let event = try ObjectiveEvent(
      id: .init(
        rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!),
      kind: .stableStateObservation, occurredAt: date, timeZoneIdentifier: "UTC",
      source: .init(
        collector: .applicationWindowContext, collectorVersion: "test", payloadSchemaVersion: 1),
      securityDisposition: .allowed)
    _ = try await objective.insert(event)
    sessions.append(
      try Session(
        id: .init(
          rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 11))!),
        displayID: DisplayID(), startedAt: date, endedAt: date.addingTimeInterval(60),
        objectiveEventIDs: [event.id]))
  }
  let sessionRepository = try SQLiteSessionRepository(location: .file(url))
  #expect(
    try await sessionRepository.save(
      try SessionDerivationBatch(day: day, derivationRevision: 1, sessions: sessions)) == .inserted)
  try await body(url, day, try SQLiteActivityRepository(location: .file(url)), sessions)
}

private func withTemporaryActivityDatabase(_ body: (URL) async throws -> Void) async throws {
  let url = URL(fileURLWithPath: "/tmp/dayday-activity-open-\(UUID().uuidString).sqlite")
  defer {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
  try await body(url)
}

private func execute(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database
  else { throw POSIXError(.EIO) }
  defer { sqlite3_close_v2(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
}
