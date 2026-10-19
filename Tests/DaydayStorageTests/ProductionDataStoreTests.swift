import CSQLite
import Darwin
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("Production data-store composition", .serialized)
struct ProductionDataStoreTests {
  @Test("opens both versioned repositories in one owner-only database")
  func opensBothRepositories() async throws {
    try await withSecureBase { base in
      let store = try ProductionDataStore.open(baseApplicationSupportURL: base)

      #expect(try await store.objectiveEvents.schemaVersion() == 4)
      #expect(try await store.inputAggregates.schemaVersion() == 2)
      #expect(try await store.collectionConsents.schemaVersion() == 1)
      #expect(try await store.workReports.schemaVersion() == 2)
      #expect(try await store.journalEntries.schemaVersion() == 2)
      #expect(try await store.journalFragments.schemaVersion() == 1)
      #expect(try await store.deepCaptureArchive.schemaVersion() == 3)
      #expect(
        try await store.collectionConsents.globalControl()
          == GlobalCollectionControl(isPaused: false, revision: 0))
      var utcCalendar = Calendar(identifier: .gregorian)
      utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
      let emptyDayStart = try #require(
        utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 4))
      )
      let emptyDayEnd = try #require(
        utcCalendar.date(byAdding: .day, value: 1, to: emptyDayStart)
      )
      let emptyDay = try DayDescriptor(
        logicalDate: .init(year: 2026, month: 8, day: 4), timeZoneIdentifier: "UTC",
        boundary: .init(
          hour: 4,
          startsAt: emptyDayStart,
          endsAt: emptyDayEnd
        )
      )
      #expect(try await store.understandingDerivations.latest(for: emptyDay) == nil)

      let database = try #require(fileURL(from: store.location))
      #expect(
        try sessionSchemaVersion(at: database) == SQLiteSessionRepository.currentSchemaVersion)
      #expect(
        try activitySchemaVersion(at: database) == SQLiteActivityRepository.currentSchemaVersion)
      #expect(
        try activitySchemaFingerprint(at: database)
          == SQLiteActivityRepository.expectedSchemaFingerprint)
      #expect(try permissions(of: database.deletingLastPathComponent()) == 0o700)
      #expect(try permissions(of: database) == 0o600)

      let reopened = try ProductionDataStore.open(baseApplicationSupportURL: base)
      #expect(
        try sessionSchemaVersion(at: try #require(fileURL(from: reopened.location)))
          == SQLiteSessionRepository.currentSchemaVersion)
      #expect(
        try activitySchemaVersion(at: try #require(fileURL(from: reopened.location)))
          == SQLiteActivityRepository.currentSchemaVersion)
      #expect(try await reopened.objectiveEvents.schemaVersion() == 4)
      #expect(
        try await reopened.inputAggregates.schemaFingerprint()
          == SQLiteInputAggregateRepository.expectedSchemaFingerprint)
      #expect(
        try await reopened.workReports.schemaFingerprint()
          == SQLiteWorkReportRepository.expectedSchemaFingerprint)
      #expect(
        try await reopened.deepCaptureArchive.schemaFingerprint()
          == SQLiteDeepCaptureArchiveRepository.expectedSchemaFingerprint)
      #expect(
        try await reopened.journalEntries.schemaFingerprint()
          == SQLiteJournalEntryRepository.expectedSchemaFingerprint)
      #expect(
        try await reopened.journalFragments.schemaFingerprint()
          == SQLiteJournalFragmentRepository.expectedSchemaFingerprint)
      #expect(try await reopened.understandingDerivations.latest(for: emptyDay) == nil)
    }
  }

  @Test("writeability probe commits without changing durable state or leaving marker residue")
  func writeabilityProbeIsSemanticPreserving() async throws {
    try await withSecureBase { base in
      let store = try ProductionDataStore.open(baseApplicationSupportURL: base)
      let directory = try #require(fileURL(from: store.location)).deletingLastPathComponent()
      let database = try #require(fileURL(from: store.location))
      let wal = URL(fileURLWithPath: database.path + "-wal")
      let controlBefore = try await store.collectionConsents.globalControl()

      try execute("PRAGMA wal_checkpoint(TRUNCATE)", at: database)
      #expect(try fileSize(of: wal) == 0)
      try await store.verifyWritable()
      #expect(try fileSize(of: wal) > 0)
      try await store.verifyWritable()

      #expect(try await store.collectionConsents.globalControl() == controlBefore)
      #expect(try probeArtifacts(in: directory).isEmpty)
      #expect(try await store.collectionStopIntents.unresolved().isEmpty)

      let reopened = try ProductionDataStore.open(baseApplicationSupportURL: base)
      try await reopened.verifyWritable()
      #expect(try await reopened.collectionConsents.globalControl() == controlBefore)
      #expect(try probeArtifacts(in: directory).isEmpty)
    }
  }

  @Test("writeability probe fails within its bounded window behind a held SQLite writer")
  func heldWriteLockFailsByDeadline() async throws {
    try await withSecureBase { base in
      let store = try ProductionDataStore.open(baseApplicationSupportURL: base)
      let database = try #require(fileURL(from: store.location))
      let lock = try ProductionStoreExclusiveLock(url: database)
      let started = DispatchTime.now().uptimeNanoseconds

      do {
        try await store.verifyWritable()
        Issue.record("Expected writeability probe to fail while the write lock is held")
      } catch let error as ObjectiveEventStoreError {
        guard case .database(let code, _) = error else {
          Issue.record("Expected SQLite database error, received \(error)")
          return
        }
        #expect(code & 0xFF == SQLITE_BUSY || code & 0xFF == SQLITE_LOCKED)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(elapsed >= 900_000_000)
        #expect(elapsed < 2_000_000_000)
      }
      withExtendedLifetime(lock) {}
    }
  }

  @Test("writeability probe rejects a substituted stop-intent directory without redirection")
  func writeabilityProbeRejectsDirectorySubstitution() async throws {
    try await withSecureBase { base in
      let store = try ProductionDataStore.open(baseApplicationSupportURL: base)
      let original = try #require(fileURL(from: store.location)).deletingLastPathComponent()
      let retired = base.appendingPathComponent("retired-dayday", isDirectory: true)
      try FileManager.default.moveItem(at: original, to: retired)
      let replacementTarget = base.appendingPathComponent("replacement-target", isDirectory: true)
      try FileManager.default.createDirectory(
        at: replacementTarget,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      try FileManager.default.createSymbolicLink(
        at: original, withDestinationURL: replacementTarget)

      await #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
        try await store.verifyWritable()
      }
      #expect(try probeArtifacts(in: retired).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: replacementTarget.path).isEmpty)
    }
  }

  @Test("a cancelled startup fails before running the writeability probe")
  func cancelledProbeFailsBeforeWriting() async throws {
    try await withSecureBase { base in
      let store = try ProductionDataStore.open(baseApplicationSupportURL: base)
      let directory = try #require(fileURL(from: store.location)).deletingLastPathComponent()
      let gate = ProductionProbeStartGate()
      let probe = Task {
        await gate.park()
        try await store.verifyWritable()
      }
      await gate.waitUntilParked()
      probe.cancel()
      await gate.release()

      await #expect(throws: CancellationError.self) {
        try await probe.value
      }
      #expect(try probeArtifacts(in: directory).isEmpty)
    }
  }

  @Test("refuses an unsafe shared base before opening repositories")
  func refusesUnsafeBase() async throws {
    try await withSecureBase { base in
      guard chmod(base.path, 0o777) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      #expect(throws: SecureDatabaseLocation.PreparationError.unsafeBaseDirectory) {
        _ = try ProductionDataStore.open(baseApplicationSupportURL: base)
      }
    }
  }

  @Test("concurrent first opens serialize both namespace migrations")
  func concurrentFirstOpen() async throws {
    for _ in 0..<20 {
      try await withSecureBase { base in
        let gate = ProductionDataStoreOpenGate(participantCount: 12)
        let stores = try await withThrowingTaskGroup(
          of: ProductionDataStore.self,
          returning: [ProductionDataStore].self
        ) { group in
          for _ in 0..<12 {
            group.addTask {
              await gate.wait()
              return try ProductionDataStore.open(baseApplicationSupportURL: base)
            }
          }
          var result: [ProductionDataStore] = []
          for try await store in group { result.append(store) }
          return result
        }

        #expect(stores.count == 12)
        for store in stores {
          #expect(try await store.objectiveEvents.schemaVersion() == 4)
          #expect(try await store.inputAggregates.schemaVersion() == 2)
          #expect(
            try sessionSchemaVersion(at: try #require(fileURL(from: store.location)))
              == SQLiteSessionRepository.currentSchemaVersion)
          #expect(
            try activitySchemaVersion(at: try #require(fileURL(from: store.location)))
              == SQLiteActivityRepository.currentSchemaVersion)
          #expect(
            try activitySchemaFingerprint(at: try #require(fileURL(from: store.location)))
              == SQLiteActivityRepository.expectedSchemaFingerprint)
        }
      }
    }
  }

  @Test("SQLite open rejects a final-component symbolic link")
  func noFollowRejectsSymbolicLink() async throws {
    try await withSecureBase { base in
      let target = base.appendingPathComponent("outside.sqlite3")
      try Data().write(to: target, options: .withoutOverwriting)

      for (name, open) in [
        (
          "objective-link.sqlite3",
          { (url: URL) throws in
            _ = try SQLiteObjectiveEventRepository(location: .file(url))
          }
        ),
        (
          "input-link.sqlite3",
          { (url: URL) throws in
            _ = try SQLiteInputAggregateRepository(location: .file(url))
          }
        ),
      ] {
        let link = base.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
          try open(link)
          Issue.record("Expected SQLite to reject a symbolic-link filename")
        } catch let error as ObjectiveEventStoreError {
          guard case .database(let code, _) = error else {
            Issue.record("Unexpected objective-store error: \(error)")
            continue
          }
          #expect(code & 0xFF == SQLITE_CANTOPEN)
        } catch let error as InputAggregateStoreError {
          guard case .database(let code, _) = error else {
            Issue.record("Unexpected aggregate-store error: \(error)")
            continue
          }
          #expect(code & 0xFF == SQLITE_CANTOPEN)
        }
      }
    }
  }

  @Test("a corrupt repository namespace prevents the composition from returning")
  func corruptNamespaceFailsWholeComposition() async throws {
    for corruptedIndex in ["objective_events_occurred_at", "input_aggregates_period_start"] {
      try await withSecureBase { base in
        let location = try SecureDatabaseLocation.prepare(
          baseApplicationSupportURL: base
        )
        do {
          _ = try SQLiteObjectiveEventRepository(location: location)
          _ = try SQLiteInputAggregateRepository(location: location)
        }
        let database = try #require(fileURL(from: location))
        try execute("DROP INDEX \(corruptedIndex)", at: database)

        #expect(throws: (any Error).self) {
          _ = try ProductionDataStore.open(baseApplicationSupportURL: base)
        }
      }
    }
  }

  private actor ProductionDataStoreOpenGate {
    private let participantCount: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
      self.participantCount = participantCount
    }

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

  private func withSecureBase(
    _ body: (URL) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayday-production-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let base = root.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(
      at: base,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try await body(base)
  }

  private func fileURL(from location: SQLiteDatabaseLocation) -> URL? {
    guard case .file(let url) = location else { return nil }
    return url
  }

  private func permissions(of url: URL) throws -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return status.st_mode & 0o777
  }

  private func fileSize(of url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.size] as? NSNumber else { throw POSIXError(.EIO) }
    return value.int64Value
  }

  private func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(
      canonicalSQLiteFilePath(url),
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard opened == SQLITE_OK, let database else {
      if let database { sqlite3_close_v2(database) }
      throw POSIXError(.EIO)
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw POSIXError(.EIO)
    }
  }

  private func sessionSchemaVersion(at url: URL) throws -> Int64 {
    try schemaInteger(
      "SELECT schema_version FROM h2_session_schema_metadata WHERE singleton = 1", at: url)
  }

  private func activitySchemaVersion(at url: URL) throws -> Int64 {
    try schemaInteger(
      "SELECT schema_version FROM h2_activity_schema_metadata WHERE singleton = 1", at: url)
  }

  private func activitySchemaFingerprint(at url: URL) throws -> String {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
    else { throw POSIXError(.EIO) }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database,
        "SELECT schema_fingerprint FROM h2_activity_schema_metadata WHERE singleton = 1",
        -1,
        &statement,
        nil
      ) == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW
    else { throw POSIXError(.EIO) }
    defer { sqlite3_finalize(statement) }
    guard let value = sqlite3_column_text(statement, 0) else { throw POSIXError(.EIO) }
    return String(cString: value)
  }

  private func schemaInteger(_ sql: String, at url: URL) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database
    else { throw POSIXError(.EIO) }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement,
      sqlite3_step(statement) == SQLITE_ROW
    else { throw POSIXError(.EIO) }
    defer { sqlite3_finalize(statement) }
    return sqlite3_column_int64(statement, 0)
  }

  private func probeArtifacts(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.contains("writeability-probe")
    }
  }
}

private final class ProductionStoreExclusiveLock {
  private let database: OpaquePointer

  init(url: URL) throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      canonicalSQLiteFilePath(url),
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      if let opened { sqlite3_close_v2(opened) }
      throw POSIXError(.EIO)
    }
    database = opened
    guard sqlite3_busy_timeout(database, 1_000) == SQLITE_OK else {
      sqlite3_close_v2(database)
      throw POSIXError(.EIO)
    }
    var message: UnsafeMutablePointer<CChar>?
    let begin = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, &message)
    guard begin == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "SQLite error"
      sqlite3_free(message)
      sqlite3_close_v2(database)
      throw ProductionStoreLockError.execute(begin, text)
    }
  }

  deinit {
    sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
    sqlite3_close_v2(database)
  }
}

private enum ProductionStoreLockError: Error {
  case execute(Int32, String)
}

private actor ProductionProbeStartGate {
  private var parked = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func park() async {
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
      parked = true
      arrival?.resume()
      arrival = nil
    }
  }

  func waitUntilParked() async {
    if parked { return }
    await withCheckedContinuation { arrival = $0 }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
