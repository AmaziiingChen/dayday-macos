import CSQLite
import Darwin
import Dispatch
import Foundation

/// Canonicalizes only the already-existing parent directory. The database's
/// final path component is intentionally left unresolved so
/// `SQLITE_OPEN_NOFOLLOW` can reject a substituted symbolic link.
func canonicalSQLiteFilePath(_ url: URL) -> String? {
  guard url.isFileURL, !url.lastPathComponent.isEmpty else { return nil }
  let parentPath = url.deletingLastPathComponent().path
  guard let resolvedPointer = parentPath.withCString({ realpath($0, nil) }) else {
    return nil
  }
  defer { free(resolvedPointer) }
  let resolvedParent = String(cString: resolvedPointer)
  return URL(fileURLWithPath: resolvedParent, isDirectory: true)
    .appendingPathComponent(url.lastPathComponent, isDirectory: false)
    .path
}

final class SQLiteDatabase {
  private static let journalModeRetryDeadlineNanoseconds: UInt64 = 1_000_000_000
  private static let initialJournalModeRetryNanoseconds: UInt64 = 5_000_000
  private static let maximumJournalModeRetryNanoseconds: UInt64 = 50_000_000
  private static let deadlineInterruptCadenceNanoseconds: UInt64 = 10_000_000
  private static let writeabilityProbeDeadlineNanoseconds: UInt64 = 1_000_000_000

  private var handle: OpaquePointer?

  init(location: SQLiteDatabaseLocation) throws {
    let path: String
    switch location {
    case .inMemory:
      path = ":memory:"
    case .file(let url):
      guard let canonicalPath = canonicalSQLiteFilePath(url) else {
        throw ObjectiveEventStoreError.invalidFileURL
      }
      path = canonicalPath
    }

    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      path,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        | SQLITE_OPEN_NOFOLLOW,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
      if let opened { sqlite3_close_v2(opened) }
      throw ObjectiveEventStoreError.database(code: result, message: message)
    }
    handle = opened

    do {
      try setBusyTimeout(milliseconds: 0)
      try installImmediateBusyHandler()
      if case .file = location {
        try configureWALJournalMode()
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA synchronous = FULL")
      } else {
        try execute("PRAGMA busy_timeout = 5000")
      }
      try execute("PRAGMA foreign_keys = ON")
    } catch {
      close()
      throw error
    }
  }

  deinit {
    close()
  }

  var changedRowCount: Int32 {
    handle.map(sqlite3_changes) ?? 0
  }

  func close() {
    if let handle {
      sqlite3_close_v2(handle)
      self.handle = nil
    }
  }

  func execute(_ sql: String) throws {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw ObjectiveEventStoreError.database(code: result, message: message)
    }
  }

  private func setBusyTimeout(milliseconds: Int32) throws {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }
    let result = sqlite3_busy_timeout(handle, milliseconds)
    guard result == SQLITE_OK else {
      throw ObjectiveEventStoreError.database(
        code: result,
        message: String(cString: sqlite3_errmsg(handle))
      )
    }
  }

  private func installImmediateBusyHandler() throws {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }
    let result = sqlite3_busy_handler(handle, daydayImmediateBusyHandler, nil)
    guard result == SQLITE_OK else {
      throw ObjectiveEventStoreError.database(
        code: result,
        message: String(cString: sqlite3_errmsg(handle))
      )
    }
  }

  /// `journal_mode` takes a database-wide lock outside the repository migration transaction.
  /// WAL convergence uses a zero busy timeout and an immediate busy handler, then arms a
  /// one-second monotonic `sqlite3_interrupt` deadline for SQLite calls that do not honor that
  /// handler. After the deadline, interruption repeats every ten milliseconds until this method
  /// exits, so an interrupt that lands between attempts cannot be consumed. The test accepts a
  /// two-second wall-clock completion to include one second of scheduler tolerance; a process
  /// suspended by the OS has no hard wall-clock bound. Normal operations regain the five-second
  /// SQLite busy timeout afterward.
  private func configureWALJournalMode() throws {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + Self.journalModeRetryDeadlineNanoseconds
    let interruptionQueue = DispatchQueue(label: "app.dayday.sqlite-wal-deadline")
    let interruptionTimer = DispatchSource.makeTimerSource(queue: interruptionQueue)
    interruptionTimer.schedule(
      deadline: .now() + .nanoseconds(Int(Self.journalModeRetryDeadlineNanoseconds)),
      repeating: .nanoseconds(Int(Self.deadlineInterruptCadenceNanoseconds))
    )
    interruptionTimer.setEventHandler { sqlite3_interrupt(handle) }
    interruptionTimer.resume()
    defer {
      interruptionTimer.setEventHandler {}
      interruptionTimer.cancel()
      interruptionQueue.sync {}
    }

    var retryNanoseconds = Self.initialJournalModeRetryNanoseconds

    while true {
      try throwIfWALDeadlinePassed(deadline)
      do {
        try execute("PRAGMA journal_mode = WAL")
        try throwIfWALDeadlinePassed(deadline)
        let statement = try prepare("PRAGMA journal_mode")
        try throwIfWALDeadlinePassed(deadline)
        guard try statement.stepRow() else {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_ERROR,
            message: "SQLite did not enter WAL journal mode"
          )
        }
        guard try statement.requiredText(at: 0, column: "journal_mode").lowercased() == "wal" else {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_ERROR,
            message: "SQLite did not enter WAL journal mode"
          )
        }
        try throwIfWALDeadlinePassed(deadline)
        guard !(try statement.stepRow()) else {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_ERROR,
            message: "SQLite did not enter WAL journal mode"
          )
        }
        return
      } catch let error as ObjectiveEventStoreError {
        let now = DispatchTime.now().uptimeNanoseconds
        if Self.isDeadlineInterruption(error), now >= deadline {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_BUSY,
            message: "Timed out waiting to enter WAL journal mode"
          )
        }
        guard Self.isRetryableJournalModeError(error) else { throw error }

        guard now < deadline else { throw error }
        let delay = min(retryNanoseconds, deadline - now)
        Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000)
        try throwIfWALDeadlinePassed(deadline)
        retryNanoseconds = min(
          retryNanoseconds * 2,
          Self.maximumJournalModeRetryNanoseconds
        )
      }
    }
  }

  private func throwIfWALDeadlinePassed(_ deadline: UInt64) throws {
    guard DispatchTime.now().uptimeNanoseconds < deadline else {
      throw ObjectiveEventStoreError.database(
        code: SQLITE_BUSY,
        message: "Timed out waiting to enter WAL journal mode"
      )
    }
  }

  private static func isRetryableJournalModeError(_ error: ObjectiveEventStoreError) -> Bool {
    guard case .database(let code, _) = error else { return false }
    switch code & 0xFF {
    case SQLITE_BUSY, SQLITE_LOCKED:
      return true
    default:
      return false
    }
  }

  private static func isDeadlineInterruption(_ error: ObjectiveEventStoreError) -> Bool {
    guard case .database(let code, _) = error else { return false }
    return code & 0xFF == SQLITE_INTERRUPT
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw ObjectiveEventStoreError.database(
        code: result,
        message: String(cString: sqlite3_errmsg(handle))
      )
    }
    return SQLiteStatement(database: handle, statement: statement)
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// Proves that the production database can acquire and commit a real write transaction.
  ///
  /// Toggling the closed boolean singleton twice in one transaction forces a dirty page through
  /// the WAL commit path while restoring the exact user-visible state. The probe uses its own
  /// bounded busy policy because startup must fail closed instead of waiting indefinitely behind
  /// another writer.
  func verifyProductionStoreWritable() throws {
    guard let handle else {
      throw ObjectiveEventStoreError.corruptedSchema("Database is closed")
    }

    try setBusyTimeout(milliseconds: 0)
    try installImmediateBusyHandler()
    defer { try? setBusyTimeout(milliseconds: 5_000) }

    let deadline =
      DispatchTime.now().uptimeNanoseconds
      + Self.writeabilityProbeDeadlineNanoseconds
    let interruptionQueue = DispatchQueue(label: "app.dayday.sqlite-writeability-deadline")
    let interruptionTimer = DispatchSource.makeTimerSource(queue: interruptionQueue)
    interruptionTimer.schedule(
      deadline: .now() + .nanoseconds(Int(Self.writeabilityProbeDeadlineNanoseconds)),
      repeating: .nanoseconds(Int(Self.deadlineInterruptCadenceNanoseconds))
    )
    interruptionTimer.setEventHandler { sqlite3_interrupt(handle) }
    interruptionTimer.resume()
    defer {
      interruptionTimer.setEventHandler {}
      interruptionTimer.cancel()
      interruptionQueue.sync {}
    }

    var retryNanoseconds = Self.initialJournalModeRetryNanoseconds
    while true {
      try throwIfWriteabilityProbeDeadlinePassed(deadline)
      do {
        try execute("BEGIN IMMEDIATE")
        do {
          for _ in 0..<2 {
            let statement = try prepare(
              "UPDATE collection_global_control SET is_paused = 1 - is_paused WHERE singleton=1"
            )
            try statement.expectDone()
            guard changedRowCount == 1 else {
              throw ObjectiveEventStoreError.corruptedSchema(
                "Collection global control singleton is missing"
              )
            }
          }
          try throwIfWriteabilityProbeDeadlinePassed(deadline)
          try execute("COMMIT")
          try throwIfWriteabilityProbeDeadlinePassed(deadline)
          return
        } catch {
          try? execute("ROLLBACK")
          throw error
        }
      } catch let error as ObjectiveEventStoreError {
        let now = DispatchTime.now().uptimeNanoseconds
        if Self.isDeadlineInterruption(error), now >= deadline {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_BUSY,
            message: "Timed out verifying production database writeability"
          )
        }
        guard Self.isRetryableJournalModeError(error) else { throw error }
        guard now < deadline else {
          throw ObjectiveEventStoreError.database(
            code: SQLITE_BUSY,
            message: "Timed out verifying production database writeability"
          )
        }
        let delay = min(retryNanoseconds, deadline - now)
        Thread.sleep(forTimeInterval: Double(delay) / 1_000_000_000)
        retryNanoseconds = min(
          retryNanoseconds * 2,
          Self.maximumJournalModeRetryNanoseconds
        )
      }
    }
  }

  private func throwIfWriteabilityProbeDeadlinePassed(_ deadline: UInt64) throws {
    guard DispatchTime.now().uptimeNanoseconds < deadline else {
      throw ObjectiveEventStoreError.database(
        code: SQLITE_BUSY,
        message: "Timed out verifying production database writeability"
      )
    }
  }

  func tableExists(_ name: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ? LIMIT 1"
    )
    try statement.bind(name, at: 1)
    return try statement.stepRow()
  }

  func schemaSQL(type: String, name: String) throws -> String? {
    let statement = try prepare(
      "SELECT sql FROM sqlite_schema WHERE type = ? AND name = ? LIMIT 1"
    )
    try statement.bind(type, at: 1)
    try statement.bind(name, at: 2)
    guard try statement.stepRow() else { return nil }
    return try statement.requiredText(at: 0, column: "sqlite_schema.sql")
  }

  func schemaObjectNames(withPrefix prefix: String) throws -> [String] {
    let statement = try prepare(
      "SELECT name FROM sqlite_schema WHERE name LIKE ? ESCAPE '\\' ORDER BY name ASC"
    )
    let escaped = prefix
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    try statement.bind(escaped + "%", at: 1)
    var names: [String] = []
    while try statement.stepRow() {
      names.append(try statement.requiredText(at: 0, column: "sqlite_schema.name"))
    }
    return names
  }
}

private func daydayImmediateBusyHandler(
  _ context: UnsafeMutableRawPointer?,
  _ count: Int32
) -> Int32 {
  0
}

final class SQLiteStatement {
  private let database: OpaquePointer
  private var statement: OpaquePointer?

  init(database: OpaquePointer, statement: OpaquePointer) {
    self.database = database
    self.statement = statement
  }

  deinit {
    if let statement {
      sqlite3_finalize(statement)
    }
  }

  func bind(_ value: String, at index: Int32) throws {
    try check(sqlite3_bind_text(statement, index, value, -1, dayday_sqlite_transient()))
  }

  func bind(_ value: Int64, at index: Int32) throws {
    try check(sqlite3_bind_int64(statement, index, value))
  }

  func bind(_ value: Double, at index: Int32) throws {
    try check(sqlite3_bind_double(statement, index, value))
  }

  func bind(_ value: Data, at index: Int32) throws {
    try value.withUnsafeBytes { bytes in
      try check(
        sqlite3_bind_blob(
          statement, index, bytes.baseAddress, Int32(bytes.count), dayday_sqlite_transient()))
    }
  }

  func bindNull(at index: Int32) throws {
    try check(sqlite3_bind_null(statement, index))
  }

  func stepRow() throws -> Bool {
    let result = sqlite3_step(statement)
    switch result {
    case SQLITE_ROW:
      return true
    case SQLITE_DONE:
      return false
    default:
      throw databaseError(code: result)
    }
  }

  func expectDone() throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw databaseError(code: result)
    }
  }

  func isNull(at index: Int32) -> Bool {
    sqlite3_column_type(statement, index) == SQLITE_NULL
  }

  func requiredText(at index: Int32, column: String) throws -> String {
    guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
      let pointer = sqlite3_column_text(statement, index)
    else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: column)
    }
    return String(cString: pointer)
  }

  func requiredInt64(at index: Int32, column: String) throws -> Int64 {
    guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: column)
    }
    return sqlite3_column_int64(statement, index)
  }

  func requiredDouble(at index: Int32, column: String) throws -> Double {
    let type = sqlite3_column_type(statement, index)
    guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else {
      throw ObjectiveEventStoreError.invalidStoredValue(column: column)
    }
    return sqlite3_column_double(statement, index)
  }

  func requiredData(at index: Int32, column: String) throws -> Data {
    guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
      let pointer = sqlite3_column_blob(statement, index)
    else { throw ObjectiveEventStoreError.invalidStoredValue(column: column) }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
  }

  private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else {
      throw databaseError(code: result)
    }
  }

  private func databaseError(code: Int32) -> ObjectiveEventStoreError {
    ObjectiveEventStoreError.database(
      code: code,
      message: String(cString: sqlite3_errmsg(database))
    )
  }
}
