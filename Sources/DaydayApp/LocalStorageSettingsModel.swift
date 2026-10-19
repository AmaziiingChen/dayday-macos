import AppKit
import Foundation

@MainActor
final class LocalStorageSettingsModel: ObservableObject {
  struct Snapshot: Equatable, Sendable {
    let byteCount: Int64
    let fileCount: Int
    let isAvailable: Bool

    static let unavailable = Snapshot(byteCount: 0, fileCount: 0, isAvailable: false)
  }

  @Published private(set) var snapshot = Snapshot.unavailable
  @Published private(set) var isRefreshing = false

  private let directoryURL: URL

  init(directoryURL: URL? = nil) {
    if let directoryURL {
      self.directoryURL = directoryURL
    } else {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      self.directoryURL = base.appendingPathComponent("Dayday", isDirectory: true)
    }
  }

  var sizeDescription: String {
    ByteCountFormatter.string(fromByteCount: snapshot.byteCount, countStyle: .file)
  }

  var filesDescription: String {
    snapshot.fileCount == 1 ? "1 个本地文件" : "\(snapshot.fileCount) 个本地文件"
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let directoryURL = directoryURL
    Task { [weak self] in
      let scanned = await Task.detached(priority: .utility) {
        Self.scan(directoryURL: directoryURL)
      }.value
      guard let self else { return }
      snapshot = scanned
      isRefreshing = false
    }
  }

  func revealInFinder() {
    guard snapshot.isAvailable else { return }
    NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
  }

  nonisolated private static func scan(directoryURL: URL) -> Snapshot {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directoryURL.path) else { return .unavailable }
    guard let enumerator = manager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return .unavailable }

    var byteCount: Int64 = 0
    var fileCount = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      byteCount += Int64(values.fileSize ?? 0)
      fileCount += 1
    }
    return Snapshot(byteCount: byteCount, fileCount: fileCount, isAvailable: true)
  }
}
