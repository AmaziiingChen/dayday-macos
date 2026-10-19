@testable import DaydayApp
import Foundation
import Testing
import Darwin

@Suite("Today work-note persistence")
@MainActor
struct AppDraftStoreTests {
  @Test("Work note round-trips through an app-owned local file")
  func roundTrip() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkNoteFileStore(directoryURL: directory)
    let drafts = AppDraftStore(workNotePersistence: store, saveDelay: .seconds(60))

    drafts.workNote = "确认了发布范围，并补充了风险。"
    drafts.flushPendingWorkNoteSave()

    let restored = AppDraftStore(workNotePersistence: store, saveDelay: .seconds(60))
    #expect(restored.workNote == "确认了发布范围，并补充了风险。")
    #expect(restored.workNotePersistenceError == nil)
  }

  @Test("An empty work note is persisted as an empty value")
  func emptyValue() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkNoteFileStore(directoryURL: directory)
    let drafts = AppDraftStore(workNotePersistence: store, saveDelay: .seconds(60))

    drafts.workNote = "temporary"
    drafts.flushPendingWorkNoteSave()
    drafts.workNote = ""
    drafts.flushPendingWorkNoteSave()

    #expect(AppDraftStore(workNotePersistence: store).workNote.isEmpty)
  }

  @Test("Oversized work notes are safely bounded at a UTF-8 character boundary")
  func boundedOversizedInput() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkNoteFileStore(directoryURL: directory)
    let drafts = AppDraftStore(workNotePersistence: store, saveDelay: .seconds(60))
    let oversized = String(repeating: "日", count: WorkNoteFileStore.maximumUTF8ByteCount)

    drafts.workNote = oversized
    drafts.flushPendingWorkNoteSave()

    #expect(drafts.workNote.utf8.count <= WorkNoteFileStore.maximumUTF8ByteCount)
    #expect(drafts.workNote.unicodeScalars.allSatisfy { $0 == "日".unicodeScalars.first! })
    #expect(AppDraftStore(workNotePersistence: store).workNote == drafts.workNote)
  }

  @Test("Invalid local bytes fail safe and are replaced only by a later user edit")
  func corruptionRecovery() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("work-note.txt")
    try Data([0xFF, 0xFE]).write(to: fileURL)
    let store = WorkNoteFileStore(directoryURL: directory)
    let drafts = AppDraftStore(workNotePersistence: store, saveDelay: .seconds(60))

    #expect(drafts.workNote.isEmpty)
    #expect(drafts.workNotePersistenceError == .corrupted)
    drafts.workNote = "用户确认的工作事实"
    drafts.flushPendingWorkNoteSave()

    let restored = AppDraftStore(workNotePersistence: store)
    #expect(restored.workNote == "用户确认的工作事实")
    #expect(restored.workNotePersistenceError == nil)
  }

  @Test("Rapid edits coalesce into one debounced save of the latest work note")
  func rapidEditDebounce() async throws {
    let persistence = RecordingWorkNotePersistence()
    let drafts = AppDraftStore(workNotePersistence: persistence, saveDelay: .milliseconds(25))

    drafts.workNote = "first"
    drafts.workNote = "second"
    drafts.workNote = "latest"
    try await Task.sleep(for: .milliseconds(80))

    #expect(persistence.savedValues == ["latest"])
  }

  @Test("Explicit flush preserves an edit that has not reached the debounce deadline")
  func flushPreservesPendingEdit() {
    let persistence = RecordingWorkNotePersistence()
    let drafts = AppDraftStore(workNotePersistence: persistence, saveDelay: .seconds(60))

    drafts.workNote = "最后一条工作事实"
    drafts.flushPendingWorkNoteSave()

    #expect(persistence.savedValues == ["最后一条工作事实"])
  }

  @Test("A write failure remains visible and does not discard the note in memory")
  func writeFailure() {
    let persistence = RecordingWorkNotePersistence(writeError: .writeFailed)
    let drafts = AppDraftStore(workNotePersistence: persistence, saveDelay: .seconds(60))

    drafts.workNote = "需要保留的事实"
    drafts.flushPendingWorkNoteSave()

    #expect(drafts.workNote == "需要保留的事实")
    #expect(drafts.workNotePersistenceError == .writeFailed)
  }

  @Test("Store converges its directory and note file to owner-only permissions")
  func ownerOnlyPermissions() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try setPermissions(0o777, at: directory)
    let store = WorkNoteFileStore(directoryURL: directory)

    try store.save("私人工作事实")

    #expect(try permissions(of: directory) == 0o700)
    #expect(try permissions(of: directory.appendingPathComponent("work-note.txt")) == 0o600)
  }

  @Test("A symlinked work-note directory is rejected without writing its target")
  func rejectsSymlinkedDirectory() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target", isDirectory: true)
    let link = root.appendingPathComponent("Dayday", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try createSymbolicLink(at: link, pointingTo: target)
    let store = WorkNoteFileStore(directoryURL: link)

    #expect(throws: WorkNotePersistenceError.self) { try store.load() }
    #expect(throws: WorkNotePersistenceError.self) { try store.save("must not escape") }
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("work-note.txt").path))
  }

  @Test("A symlinked work-note file is rejected without changing its target")
  func rejectsSymlinkedFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("outside.txt")
    let note = directory.appendingPathComponent("work-note.txt")
    try Data("outside content".utf8).write(to: target)
    try createSymbolicLink(at: note, pointingTo: target)
    let store = WorkNoteFileStore(directoryURL: directory)

    #expect(throws: WorkNotePersistenceError.self) { try store.load() }
    #expect(throws: WorkNotePersistenceError.self) { try store.save("must not follow") }
    #expect(try String(contentsOf: target, encoding: .utf8) == "outside content")
  }

  @Test("A hard-linked work-note file is rejected without mutating its target")
  func rejectsHardLinkedFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("outside.txt")
    let note = directory.appendingPathComponent("work-note.txt")
    try Data("outside content".utf8).write(to: target)
    try createHardLink(from: target, to: note)
    let store = WorkNoteFileStore(directoryURL: directory)

    #expect(throws: WorkNotePersistenceError.self) { try store.load() }
    #expect(throws: WorkNotePersistenceError.self) { try store.save("must not replace") }
    #expect(try String(contentsOf: target, encoding: .utf8) == "outside content")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DaydayAppDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func setPermissions(_ mode: mode_t, at url: URL) throws {
    guard url.path.withCString({ chmod($0, mode) }) == 0 else { throw POSIXError(.EACCES) }
  }

  private func permissions(of url: URL) throws -> mode_t {
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw POSIXError(.ENOENT) }
    return status.st_mode & 0o777
  }

  private func createSymbolicLink(at link: URL, pointingTo target: URL) throws {
    guard link.path.withCString({ linkPath in target.path.withCString { symlink($0, linkPath) } }) == 0
    else { throw POSIXError(.EACCES) }
  }

  private func createHardLink(from source: URL, to destination: URL) throws {
    guard source.path.withCString({ sourcePath in destination.path.withCString { link(sourcePath, $0) } }) == 0
    else { throw POSIXError(.EACCES) }
  }
}

@MainActor
private final class RecordingWorkNotePersistence: WorkNotePersisting {
  private let initialValue: String
  private let writeError: WorkNotePersistenceError?
  private(set) var savedValues: [String] = []

  init(initialValue: String = "", writeError: WorkNotePersistenceError? = nil) {
    self.initialValue = initialValue
    self.writeError = writeError
  }

  func load() throws -> String { initialValue }

  func save(_ workNote: String) throws {
    if let writeError { throw writeError }
    savedValues.append(workNote)
  }
}
