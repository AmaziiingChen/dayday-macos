import Darwin
import DaydayCore
import Foundation

public enum CollectionStopIntentStoreError: Error, Equatable, Sendable {
  case invalidMarker
  case conflict
  case fileSystem
}

/// Owner-only, bounded stop-intent marker. Every operation is relative to an
/// opened directory descriptor so a post-prepare path substitution fails closed.
public actor CollectionStopIntentStore: CollectionStopIntentStoring {
  private struct Envelope: Codable {
    let version: Int
    let intents: [CollectionStopIntent]
  }
  private let directory: Int32
  private let directoryPath: String
  private let fileName: String

  init(markerURL: URL) throws {
    guard markerURL.isFileURL, !markerURL.lastPathComponent.isEmpty else {
      throw CollectionStopIntentStoreError.fileSystem
    }
    directoryPath = markerURL.deletingLastPathComponent().path
    let openedDirectory = try Self.openDirectory(directoryPath)
    do { try Self.validateDirectory(openedDirectory) } catch {
      close(openedDirectory)
      throw error
    }
    directory = openedDirectory
    fileName = markerURL.lastPathComponent
    do { _ = try Self.read(directory: directory, fileName: fileName) } catch {
      close(openedDirectory)
      throw error
    }
  }

  deinit { close(directory) }

  /// Verifies that the already-opened owner-only marker directory can durably create and remove
  /// a file without changing the unresolved-intent marker.
  public func verifyWritable() throws {
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    let temporary = ".\(fileName).writeability-probe.\(UUID().uuidString)"
    let descriptor = temporary.withCString {
      openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else { throw CollectionStopIntentStoreError.fileSystem }

    var needsCleanup = true
    defer {
      close(descriptor)
      if needsCleanup {
        _ = temporary.withCString { unlinkat(directory, $0, 0) }
        _ = fsync(directory)
      }
    }

    try writeAll(Data("dayday-writeability-v1".utf8), to: descriptor)
    guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
      throw CollectionStopIntentStoreError.fileSystem
    }
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    guard fsync(directory) == 0 else { throw CollectionStopIntentStoreError.fileSystem }
    guard temporary.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
      throw CollectionStopIntentStoreError.fileSystem
    }
    needsCleanup = false
    guard fsync(directory) == 0 else { throw CollectionStopIntentStoreError.fileSystem }
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
  }

  public func create(_ intent: CollectionStopIntent) throws {
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    var intents = try Self.read(directory: directory, fileName: fileName)
    guard !intents.contains(where: { $0.scope == intent.scope }),
      intents.count < CollectorKind.allCases.count + 1
    else {
      throw CollectionStopIntentStoreError.conflict
    }
    intents.append(intent)
    try replace(intents)
  }

  public func unresolved() throws -> [CollectionStopIntent] {
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    return try Self.read(directory: directory, fileName: fileName)
  }

  public func replay(using repository: any CollectionConsentRepository) async throws {
    while true {
      try Self.verifyDirectoryIdentity(directory, path: directoryPath)
      let pending = try Self.read(directory: directory, fileName: fileName)
      guard let intent = pending.first else { return }
      try await resolve(intent, using: repository)
      // An actor may accept `create` while resolution awaits its repository.
      // Re-read and remove only the exact intent that was resolved.
      try Self.verifyDirectoryIdentity(directory, path: directoryPath)
      var current = try Self.read(directory: directory, fileName: fileName)
      guard let index = current.firstIndex(where: { $0.scope == intent.scope }),
        current[index] == intent
      else {
        throw CollectionStopIntentStoreError.conflict
      }
      current.remove(at: index)
      if current.isEmpty { try remove() } else { try replace(current) }
    }
  }

  private func resolve(
    _ intent: CollectionStopIntent, using repository: any CollectionConsentRepository
  ) async throws {
    switch intent.scope {
    case .global:
      let current = try await repository.globalControl()
      if current.revision == intent.targetRevision, current.isPaused { return }
      guard current.revision == intent.expectedRevision else {
        throw CollectionStopIntentStoreError.conflict
      }
      let updated = try await repository.setGlobalPaused(
        true, expectedRevision: intent.expectedRevision)
      guard updated == GlobalCollectionControl(isPaused: true, revision: intent.targetRevision)
      else { throw CollectionStopIntentStoreError.conflict }
    case .collector(let kind):
      guard let confirmation = intent.confirmation else {
        throw CollectionStopIntentStoreError.conflict
      }
      let expectedAction: CollectorConsentActionKind =
        intent.target == .collectorPaused ? .pause : .disable
      let expectedStatus: CollectorConsentStatus =
        intent.target == .collectorPaused ? .paused : .disabled
      let current = try await repository.consent(for: kind)
      if current.revision == intent.targetRevision,
        current.consent.status == expectedStatus,
        current.lastAction == expectedAction,
        current.consent.confirmation == confirmation
      {
        return
      }
      guard current.revision == intent.expectedRevision else {
        throw CollectionStopIntentStoreError.conflict
      }
      let action: CollectorConsentAction =
        expectedAction == .pause ? .pause(confirmation) : .disable(confirmation)
      let updated = try await repository.transition(
        action, expectedRevision: intent.expectedRevision)
      guard updated.revision == intent.targetRevision,
        updated.consent.status == expectedStatus,
        updated.lastAction == expectedAction,
        updated.consent.confirmation == confirmation
      else {
        throw CollectionStopIntentStoreError.conflict
      }
    }
  }

  private static func read(directory: Int32, fileName: String) throws -> [CollectionStopIntent] {
    let descriptor = fileName.withCString {
      openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    if descriptor < 0, errno == ENOENT { return [] }
    guard descriptor >= 0 else { throw CollectionStopIntentStoreError.invalidMarker }
    defer { close(descriptor) }
    try validateExisting(descriptor)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw CollectionStopIntentStoreError.fileSystem }
      if count == 0 { break }
      data.append(buffer, count: Int(count))
      guard data.count <= 64 * 1024 else { throw CollectionStopIntentStoreError.invalidMarker }
    }
    let envelope: Envelope
    do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
      throw CollectionStopIntentStoreError.invalidMarker
    }
    guard envelope.version == 1, !envelope.intents.isEmpty,
      envelope.intents.count <= CollectorKind.allCases.count + 1,
      Set(envelope.intents.map(\.scope)).count == envelope.intents.count
    else { throw CollectionStopIntentStoreError.invalidMarker }
    for intent in envelope.intents {
      do {
        _ = try CollectionStopIntent(
          scope: intent.scope, target: intent.target, confirmation: intent.confirmation,
          expectedRevision: intent.expectedRevision, targetRevision: intent.targetRevision)
      } catch { throw CollectionStopIntentStoreError.invalidMarker }
    }
    return envelope.intents
  }

  private func replace(_ intents: [CollectionStopIntent]) throws {
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    let data: Data
    do { data = try JSONEncoder().encode(Envelope(version: 1, intents: intents)) } catch {
      throw CollectionStopIntentStoreError.invalidMarker
    }
    let temporary = ".\(fileName).\(UUID().uuidString).tmp"
    let descriptor = temporary.withCString {
      openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else { throw CollectionStopIntentStoreError.fileSystem }
    defer {
      close(descriptor)
      _ = temporary.withCString { unlinkat(directory, $0, 0) }
    }
    try writeAll(data, to: descriptor)
    guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
      throw CollectionStopIntentStoreError.fileSystem
    }
    guard temporary.withCString({ renameat(directory, $0, directory, fileName) }) == 0 else {
      throw CollectionStopIntentStoreError.fileSystem
    }
    guard fsync(directory) == 0 else { throw CollectionStopIntentStoreError.fileSystem }
  }

  private func remove() throws {
    try Self.verifyDirectoryIdentity(directory, path: directoryPath)
    // Validate the exact entry immediately before unlinking it.
    let descriptor = fileName.withCString {
      openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    if descriptor < 0, errno == ENOENT { return }
    guard descriptor >= 0 else { throw CollectionStopIntentStoreError.invalidMarker }
    defer { close(descriptor) }
    try Self.validateExisting(descriptor)
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else { throw CollectionStopIntentStoreError.fileSystem }
    var current = stat()
    guard fileName.withCString({ fstatat(directory, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
      current.st_dev == opened.st_dev, current.st_ino == opened.st_ino
    else {
      throw CollectionStopIntentStoreError.invalidMarker
    }
    guard fileName.withCString({ unlinkat(directory, $0, 0) }) == 0, fsync(directory) == 0 else {
      throw CollectionStopIntentStoreError.fileSystem
    }
  }

  private static func openDirectory(_ directoryPath: String) throws -> Int32 {
    let descriptor = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CollectionStopIntentStoreError.fileSystem }
    return descriptor
  }

  private static func validateDirectory(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700,
      try !containsExtendedACL(descriptor)
    else { throw CollectionStopIntentStoreError.invalidMarker }
  }

  private static func verifyDirectoryIdentity(_ descriptor: Int32, path: String) throws {
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0,
      lstat(path, &named) == 0,
      named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
    else {
      throw CollectionStopIntentStoreError.invalidMarker
    }
    try validateDirectory(descriptor)
  }

  private static func validateExisting(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_uid == geteuid(), status.st_nlink == 1,
      status.st_mode & 0o777 == 0o600,
      try !containsExtendedACL(descriptor)
    else { throw CollectionStopIntentStoreError.invalidMarker }
  }

  private static func containsExtendedACL(_ descriptor: Int32) throws -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT { return false }
      throw CollectionStopIntentStoreError.fileSystem
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
    if result == 0 { return true }
    if errno == EINVAL { return false }
    guard result >= 0 else { throw CollectionStopIntentStoreError.fileSystem }
    return false
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard var pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        guard count > 0 else { throw CollectionStopIntentStoreError.fileSystem }
        remaining -= Int(count)
        pointer = pointer.advanced(by: Int(count))
      }
    }
  }
}
