@testable import DaydayApp
import DaydayCore
import Darwin
import Foundation
import Testing

@Suite("Work-report working-draft persistence")
@MainActor
struct WorkReportWorkingDraftStoreTests {
  @Test("Working copy round-trips in a separate owner-only file")
  func roundTripAndPermissions() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkReportWorkingDraftFileStore(directoryURL: directory)
    let snapshot = try WorkReportWorkingDraftSnapshot(
      dayID: DayID(),
      baseRevisionID: WorkReportRevisionID(),
      body: "# 今日完成\n\n- 修复自动保存",
      updatedAt: Date(timeIntervalSince1970: 1_785_736_800)
    )

    try store.save(snapshot)

    #expect(try store.load() == snapshot)
    #expect(try permissions(of: directory) == 0o700)
    #expect(
      try permissions(of: directory.appendingPathComponent("work-report-working-draft.json"))
        == 0o600
    )

    try store.save(nil)
    #expect(try store.load() == nil)
  }

  @Test("Corrupt and unsupported working copies fail closed")
  func rejectsCorruptPayloads() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("work-report-working-draft.json")
    let store = WorkReportWorkingDraftFileStore(directoryURL: directory)

    try Data("not-json".utf8).write(to: file)
    #expect(throws: WorkReportWorkingDraftPersistenceError.corrupted) { try store.load() }

    let unsupported = """
      {"version":2,"dayID":"00000000-0000-0000-0000-000000000001",\
      "body":"text","updatedAt":0}
      """
    try Data(unsupported.utf8).write(to: file)
    #expect(throws: WorkReportWorkingDraftPersistenceError.corrupted) { try store.load() }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DaydayReportDraftTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func permissions(of url: URL) throws -> mode_t {
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw POSIXError(.ENOENT) }
    return status.st_mode & 0o777
  }
}
