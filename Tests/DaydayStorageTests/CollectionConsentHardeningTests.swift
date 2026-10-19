import CSQLite
import Darwin
import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("Collection consent persistence hardening")
struct CollectionConsentHardeningTests {
  @Test("a final-component marker symlink is rejected without touching its target")
  func rejectsMarkerSymlink() async throws {
    try await withSecureDirectory { directory in
      let target = directory.appendingPathComponent("outside")
      let original = Data("outside marker target".utf8)
      try original.write(to: target, options: .withoutOverwriting)
      try setMode(0o600, at: target)
      let marker = directory.appendingPathComponent("marker")
      try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)

      #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
        _ = try CollectionStopIntentStore(markerURL: marker)
      }
      #expect(try Data(contentsOf: target) == original)
    }
  }

  @Test("a hard-linked marker is rejected without changing the linked source")
  func rejectsMarkerHardLink() async throws {
    try await withSecureDirectory { directory in
      let source = directory.appendingPathComponent("source")
      let original = Data("linked marker source".utf8)
      try original.write(to: source, options: .withoutOverwriting)
      try setMode(0o600, at: source)
      let marker = directory.appendingPathComponent("marker")
      let result = source.path.withCString { sourcePath in
        marker.path.withCString { markerPath in link(sourcePath, markerPath) }
      }
      #expect(result == 0)

      #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
        _ = try CollectionStopIntentStore(markerURL: marker)
      }
      #expect(try Data(contentsOf: source) == original)
      #expect(try linkCount(of: source) == 2)
    }
  }

  @Test("a marker with an extended ACL is rejected, or explicitly skipped when unsupported")
  func rejectsMarkerExtendedACL() async throws {
    try await withSecureDirectory { directory in
      let marker = directory.appendingPathComponent("marker")
      try Data("ACL marker".utf8).write(to: marker, options: .withoutOverwriting)
      try setMode(0o600, at: marker)

      guard try addExtendedACLIfSupported(at: marker) else {
        #expect(
          !(try hasExtendedACL(at: marker)),
          "extended ACLs are unsupported on this temporary filesystem; marker ACL rejection was not exercised"
        )
        return
      }
      #expect(try hasExtendedACL(at: marker))
      #expect(throws: CollectionStopIntentStoreError.invalidMarker) {
        _ = try CollectionStopIntentStore(markerURL: marker)
      }
    }
  }

  @Test("non-default consent and global control persist across a production reopen")
  func reopensPersistedConsentAndGlobalControl() async throws {
    try await withProductionLocation { location in
      let confirmation = try makeConfirmation(.weather)
      let repository = try SQLiteCollectionConsentRepository(location: location)
      _ = try await repository.transition(.enable(confirmation), expectedRevision: 0)
      _ = try await repository.setGlobalPaused(true, expectedRevision: 0)

      let reopened = try SQLiteCollectionConsentRepository(location: location)
      let consent = try await reopened.consent(for: .weather)
      #expect(consent.consent.status == .enabled)
      #expect(consent.consent.confirmation == confirmation)
      #expect(consent.lastAction == .enable)
      #expect(consent.revision == 1)
      #expect(!consent.renewalRequired)
      #expect(
        try await reopened.globalControl()
          == GlobalCollectionControl(isPaused: true, revision: 1))
    }
  }

  @Test("stored consent schema, status, action, and disclosure corruption fail closed")
  func rejectsDirectStoredCorruption() async throws {
    let corruptions: [(String, String)] = [
      ("schema", "DROP TABLE collection_global_control"),
      (
        "status",
        "PRAGMA ignore_check_constraints = ON; UPDATE collection_consents SET status = 'unconfirmed'"
      ),
      (
        "action",
        "PRAGMA ignore_check_constraints = ON; UPDATE collection_consents SET last_action = 'pause'"
      ),
      ("disclosure", "UPDATE collection_consents SET disclosure_version = 'not valid disclosure'"),
    ]

    for (name, sql) in corruptions {
      try await withProductionLocation { location in
        let repository = try SQLiteCollectionConsentRepository(location: location)
        _ = try await repository.transition(
          .enable(try makeConfirmation(.weather)), expectedRevision: 0)
        try execute(sql, at: try fileURL(from: location))

        #expect(throws: (any Error).self, "\(name) corruption must prevent reopening") {
          _ = try SQLiteCollectionConsentRepository(location: location)
        }
      }
    }
  }

  @Test("status, action, and revision mismatches retain the exact stop intent")
  func retainsIntentOnExactTargetMismatch() async throws {
    let confirmation = try makeConfirmation(.weather)
    let enabled = try CollectorConsentStateMachine.transition(
      .enable(confirmation), from: CollectorConsent(collector: .weather))
    let disabled = try CollectorConsentStateMachine.transition(
      .disable(confirmation), from: enabled)
    let target = try CollectionStopIntent(
      scope: .collector(.weather), target: .collectorDisabled, confirmation: confirmation,
      expectedRevision: 0, targetRevision: 1)
    let mismatches = [
      PersistedCollectorConsent(
        consent: enabled, lastAction: .enable(confirmation), revision: 1),
      PersistedCollectorConsent(
        consent: disabled, lastAction: .pause(confirmation), revision: 1),
      PersistedCollectorConsent(
        consent: disabled, lastAction: .disable(confirmation), revision: 2),
    ]

    for mismatch in mismatches {
      try await withSecureDirectory { directory in
        let store = try CollectionStopIntentStore(
          markerURL: directory.appendingPathComponent("marker"))
        try await store.create(target)
        let repository = MismatchedConsentRepository(consent: mismatch)

        await #expect(throws: CollectionStopIntentStoreError.conflict) {
          try await store.replay(using: repository)
        }
        #expect(try await store.unresolved() == [target])
      }
    }
  }
}

private actor MismatchedConsentRepository: CollectionConsentRepository {
  private let storedConsent: PersistedCollectorConsent

  init(consent: PersistedCollectorConsent) {
    storedConsent = consent
  }

  func consent(for collector: CollectorKind) async throws -> PersistedCollectorConsent {
    storedConsent
  }

  func transition(
    _ action: CollectorConsentAction,
    expectedRevision: UInt64
  ) async throws -> PersistedCollectorConsent {
    storedConsent
  }

  func globalControl() async throws -> GlobalCollectionControl {
    GlobalCollectionControl(isPaused: false, revision: 0)
  }

  func setGlobalPaused(
    _ isPaused: Bool,
    expectedRevision: UInt64
  ) async throws -> GlobalCollectionControl {
    GlobalCollectionControl(isPaused: isPaused, revision: expectedRevision + 1)
  }
}

private func withSecureDirectory(_ body: (URL) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "dayday-consent-hardening-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try await body(directory)
}

private func withProductionLocation(
  _ body: (SQLiteDatabaseLocation) async throws -> Void
) async throws {
  try await withSecureDirectory { root in
    let base = root.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try await body(try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base))
  }
}

private func makeConfirmation(_ collector: CollectorKind) throws -> UserConsentConfirmation {
  try UserConsentConfirmation(
    collector: collector, confirmedAt: Date(timeIntervalSince1970: 100),
    disclosureVersion: "dayday-consent-v1")
}

private func fileURL(from location: SQLiteDatabaseLocation) throws -> URL {
  guard case .file(let url) = location else {
    throw CollectionConsentStoreError.invalidStoredValue("expected file-backed database")
  }
  return url
}

private func setMode(_ mode: mode_t, at url: URL) throws {
  guard url.path.withCString({ chmod($0, mode) }) == 0 else {
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }
}

private func linkCount(of url: URL) throws -> nlink_t {
  var status = stat()
  guard url.path.withCString({ lstat($0, &status) }) == 0 else {
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }
  return status.st_nlink
}

private func addExtendedACLIfSupported(at url: URL) throws -> Bool {
  let errors = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/chmod")
  process.arguments = ["+a", "everyone allow read", url.path]
  process.standardError = errors
  try process.run()
  process.waitUntilExit()
  if process.terminationStatus == 0 { return true }

  let output = String(
    decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
  if output.localizedCaseInsensitiveContains("not supported")
    || output.localizedCaseInsensitiveContains("operation not permitted")
  {
    return false
  }
  throw POSIXError(.init(rawValue: process.terminationStatus) ?? .EIO)
}

private func hasExtendedACL(at url: URL) throws -> Bool {
  let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
  guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  defer { close(descriptor) }

  errno = 0
  guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
    if errno == ENOENT { return false }
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }
  defer { acl_free(UnsafeMutableRawPointer(acl)) }
  var entry: acl_entry_t?
  let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
  if result == 0 { return true }
  if errno == EINVAL { return false }
  guard result >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  return false
}

private func execute(_ sql: String, at url: URL) throws {
  var database: OpaquePointer?
  let opened = sqlite3_open_v2(
    url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
  guard opened == SQLITE_OK, let database else {
    if let database { sqlite3_close_v2(database) }
    throw POSIXError(.EIO)
  }
  defer { sqlite3_close_v2(database) }

  var message: UnsafeMutablePointer<CChar>?
  guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
    sqlite3_free(message)
    throw POSIXError(.EIO)
  }
}
