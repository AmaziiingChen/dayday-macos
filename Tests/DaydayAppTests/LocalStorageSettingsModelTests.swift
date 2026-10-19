import Foundation
import Testing

@testable import DaydayApp

@Suite("Local storage settings")
struct LocalStorageSettingsModelTests {
  @Test
  @MainActor
  func scansOnlyRegularFilesInTheDaydayDataDirectory() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 0, count: 128).write(to: directory.appendingPathComponent("data.sqlite3"))
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("nested", isDirectory: true),
      withIntermediateDirectories: false
    )
    try Data(repeating: 1, count: 32).write(
      to: directory.appendingPathComponent("nested/sidecar")
    )

    let model = LocalStorageSettingsModel(directoryURL: directory)
    model.refresh()

    #expect(await eventually { !model.isRefreshing })
    #expect(model.snapshot.isAvailable)
    #expect(model.snapshot.fileCount == 2)
    #expect(model.snapshot.byteCount == 160)
  }

  @Test
  @MainActor
  func reportsAnUnavailableDirectoryWithoutCreatingIt() async throws {
    let directory = try makeDirectory().appendingPathComponent("missing", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let model = LocalStorageSettingsModel(directoryURL: directory)
    model.refresh()

    #expect(await eventually { !model.isRefreshing })
    #expect(!model.snapshot.isAvailable)
    #expect(model.snapshot.fileCount == 0)
    #expect(model.snapshot.byteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalStorageSettingsModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @MainActor
  private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
