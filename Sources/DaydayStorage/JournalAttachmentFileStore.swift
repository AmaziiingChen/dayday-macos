import DaydayCore
import Foundation

/// Owner-only bytes for manually imported journal images. The SQLite
/// repository carries metadata; this store owns only opaque local files.
public actor JournalAttachmentFileStore {
  public enum StoreError: Error, Equatable, Sendable {
    case fileTooLarge
    case unsafeFileName
    case unavailable
  }

  public static let maximumImageByteCount = 50 * 1_024 * 1_024
  private let directoryURL: URL

  init(location: SQLiteDatabaseLocation) throws {
    directoryURL = try SecureDatabaseLocation.journalAttachmentDirectoryURL(at: location)
  }

  public func storeImage(data: Data, fileExtension: String) throws -> JournalRelativeFileKey {
    guard !data.isEmpty, data.count <= Self.maximumImageByteCount else {
      throw StoreError.fileTooLarge
    }
    let normalized = fileExtension.lowercased()
    guard ["jpg", "jpeg", "png", "heic", "webp"].contains(normalized) else {
      throw StoreError.unsafeFileName
    }
    let key = try JournalRelativeFileKey(rawValue: "images/\(UUID().uuidString.lowercased()).\(normalized)")
    _ = try imagesDirectory()
    let url = directoryURL.appendingPathComponent(key.rawValue, isDirectory: false)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    return key
  }

  public func url(for key: JournalRelativeFileKey) throws -> URL {
    guard key.rawValue.hasPrefix("images/") else { throw StoreError.unsafeFileName }
    _ = try imagesDirectory()
    let url = directoryURL.appendingPathComponent(key.rawValue, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.unavailable }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw StoreError.unsafeFileName
    }
    return url
  }

  /// Removes a newly written byte artifact when its metadata transaction
  /// cannot be completed. Entry-facing deletion will be added with a separate
  /// attachment lifecycle contract.
  public func discard(_ key: JournalRelativeFileKey) throws {
    let url = try url(for: key)
    try FileManager.default.removeItem(at: url)
  }

  private func imagesDirectory() throws -> URL {
    let url = directoryURL.appendingPathComponent("images", isDirectory: true)
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw StoreError.unsafeFileName
      }
    } else {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: url.path
    )
    return url
  }
}
