import Darwin
import Foundation

/// Prepares Dayday's production SQLite location without following links at any
/// path component controlled by the application.
enum SecureDatabaseLocation {
  public static let applicationDirectoryName = "Dayday"
  public static let databaseFileName = "dayday.sqlite3"
  public static let collectionStopIntentFileName = "collection-stop-intent-v1"
  static let journalAttachmentDirectoryName = "journal-attachments"

  /// Errors deliberately omit absolute paths so they can be surfaced without
  /// disclosing a user's home-directory layout.
  public enum PreparationError: Error, Equatable, Sendable {
    case invalidBaseURL
    case applicationSupportUnavailable
    case unsafeBaseDirectory
    case unsafeApplicationDirectory
    case unsafeDatabaseFile
    case unsafeAuxiliaryFile(String)
    case fileSystem(operation: String, code: Int32)
  }

  /// Creates (or validates) `Dayday/dayday.sqlite3` beneath the supplied
  /// Application Support directory and converges owner permissions.
  ///
  /// Pass `nil` in production to use the current user's Application Support
  /// directory. Tests and alternate compositions should inject an explicit
  /// base URL.
  public static func prepare(
    baseApplicationSupportURL injectedBaseURL: URL? = nil
  ) throws -> SQLiteDatabaseLocation {
    let baseURL = try resolveBaseURL(injectedBaseURL)
    let baseDescriptor = try openBaseDirectory(baseURL)
    defer { Darwin.close(baseDescriptor) }

    let applicationDescriptor = try openOrCreateApplicationDirectory(
      below: baseDescriptor
    )
    defer { Darwin.close(applicationDescriptor) }

    try convergeDatabaseFile(below: applicationDescriptor)
    try convergeExistingAuxiliaryFiles(below: applicationDescriptor)
    try convergeExistingStopIntent(below: applicationDescriptor)

    let databaseURL =
      baseURL
      .appendingPathComponent(applicationDirectoryName, isDirectory: true)
      .appendingPathComponent(databaseFileName, isDirectory: false)
    return .file(databaseURL)
  }

  /// Re-applies owner-only permissions to a prepared database and any
  /// existing SQLite sidecars, including artifacts restored from backup.
  ///
  /// The macOS SQLite Unix VFS derives newly-created rollback-journal, WAL,
  /// and SHM permissions from the `0600` database file; the storage tests
  /// verify that lifecycle under a permissive process umask. This method is
  /// the defensive convergence path for artifacts that already exist.
  public static func hardenSQLiteArtifacts(
    at location: SQLiteDatabaseLocation
  ) throws {
    guard case .file(let databaseURL) = location,
      databaseURL.isFileURL,
      databaseURL.lastPathComponent == databaseFileName,
      databaseURL.deletingLastPathComponent().lastPathComponent
        == applicationDirectoryName
    else {
      throw PreparationError.invalidBaseURL
    }

    let applicationURL = databaseURL.deletingLastPathComponent()
    let descriptor = try openOwnedDirectory(
      applicationURL,
      unsafeError: .unsafeApplicationDirectory
    )
    defer { Darwin.close(descriptor) }

    try removeExtendedACL(
      descriptor,
      operation: "remove application directory ACL"
    )
    guard fchmod(descriptor, ownerDirectoryPermissions) == 0 else {
      throw PreparationError.fileSystem(
        operation: "secure application directory",
        code: errno
      )
    }

    try convergeExistingDatabaseFile(below: descriptor)
    try convergeExistingAuxiliaryFiles(below: descriptor)
    try convergeExistingStopIntent(below: descriptor)
  }

  static func stopIntentURL(at location: SQLiteDatabaseLocation) throws -> URL {
    guard case .file(let databaseURL) = location else { throw PreparationError.invalidBaseURL }
    return databaseURL.deletingLastPathComponent().appendingPathComponent(
      collectionStopIntentFileName)
  }

  /// Creates an owner-only directory beside the hardened database for private
  /// journal files. It deliberately accepts only the canonical production
  /// database location, so feature code cannot redirect attachments elsewhere.
  static func journalAttachmentDirectoryURL(at location: SQLiteDatabaseLocation) throws -> URL {
    guard case .file(let databaseURL) = location,
      databaseURL.lastPathComponent == databaseFileName
    else { throw PreparationError.invalidBaseURL }
    let applicationURL = databaseURL.deletingLastPathComponent()
    let attachmentURL = applicationURL.appendingPathComponent(
      journalAttachmentDirectoryName, isDirectory: true)
    let fileManager = FileManager.default
    var values: URLResourceValues
    if fileManager.fileExists(atPath: attachmentURL.path) {
      values = try attachmentURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw PreparationError.unsafeAuxiliaryFile(journalAttachmentDirectoryName)
      }
    } else {
      try fileManager.createDirectory(
        at: attachmentURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(ownerDirectoryPermissions))]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(ownerDirectoryPermissions))],
      ofItemAtPath: attachmentURL.path
    )
    return attachmentURL
  }

  private static let ownerDirectoryPermissions: mode_t = 0o700
  private static let ownerFilePermissions: mode_t = 0o600
  private static let auxiliarySuffixes = ["-wal", "-shm", "-journal"]

  private static func resolveBaseURL(_ injected: URL?) throws -> URL {
    let url: URL
    if let injected {
      url = injected
    } else {
      do {
        url = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
      } catch {
        throw PreparationError.applicationSupportUnavailable
      }
    }

    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw PreparationError.invalidBaseURL
    }
    return url.standardizedFileURL
  }

  private static func openBaseDirectory(_ url: URL) throws -> Int32 {
    let descriptor = try openOwnedDirectory(
      url,
      unsafeError: .unsafeBaseDirectory
    )
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw PreparationError.fileSystem(operation: "inspect base directory", code: code)
    }
    guard status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
      Darwin.close(descriptor)
      throw PreparationError.unsafeBaseDirectory
    }
    do {
      // macOS commonly adds a deny-only ACL (for example, `everyone deny
      // delete`) to the shared Application Support directory. Such an ACL
      // can only restrict access; rejecting it would prevent every production
      // store from opening on those standard installations. An allow entry,
      // however, can widen access beyond the mode bits and remains fail-closed.
      guard try !containsAccessGrantACL(descriptor) else {
        throw PreparationError.unsafeBaseDirectory
      }
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private static func openOrCreateApplicationDirectory(below baseDescriptor: Int32) throws -> Int32
  {
    let name = applicationDirectoryName
    var status = stat()
    let inspectResult = name.withCString {
      fstatat(baseDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }

    if inspectResult != 0 {
      guard errno == ENOENT else {
        throw PreparationError.fileSystem(
          operation: "inspect application directory",
          code: errno
        )
      }
      let createResult = name.withCString {
        mkdirat(baseDescriptor, $0, ownerDirectoryPermissions)
      }
      if createResult != 0, errno != EEXIST {
        throw PreparationError.fileSystem(
          operation: "create application directory",
          code: errno
        )
      }
    } else {
      guard isDirectory(status), !isSymbolicLink(status), status.st_uid == geteuid() else {
        throw PreparationError.unsafeApplicationDirectory
      }
    }

    let descriptor = name.withCString {
      openat(baseDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == ENOTDIR {
        throw PreparationError.unsafeApplicationDirectory
      }
      throw PreparationError.fileSystem(
        operation: "open application directory",
        code: errno
      )
    }

    do {
      try validateOwnedDirectoryDescriptor(
        descriptor,
        unsafeError: .unsafeApplicationDirectory
      )
      try removeExtendedACL(
        descriptor,
        operation: "remove application directory ACL"
      )
      guard fchmod(descriptor, ownerDirectoryPermissions) == 0 else {
        throw PreparationError.fileSystem(
          operation: "secure application directory",
          code: errno
        )
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func openOwnedDirectory(
    _ url: URL,
    unsafeError: PreparationError
  ) throws -> Int32 {
    let descriptor = url.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == ENOTDIR {
        throw unsafeError
      }
      throw PreparationError.fileSystem(operation: "open directory", code: errno)
    }
    do {
      try validateOwnedDirectoryDescriptor(descriptor, unsafeError: unsafeError)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func validateOwnedDirectoryDescriptor(
    _ descriptor: Int32,
    unsafeError: PreparationError
  ) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw PreparationError.fileSystem(operation: "inspect directory", code: errno)
    }
    guard isDirectory(status), status.st_uid == geteuid() else {
      throw unsafeError
    }
  }

  private static func convergeDatabaseFile(below directoryDescriptor: Int32) throws {
    do {
      try convergeExistingDatabaseFile(below: directoryDescriptor)
      return
    } catch PreparationError.fileSystem(_, let code) where code == ENOENT {
      // Create below the already-open, no-follow directory so a path swap
      // cannot redirect the new database outside Dayday's container.
    }

    let descriptor = databaseFileName.withCString {
      openat(
        directoryDescriptor,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        ownerFilePermissions
      )
    }
    if descriptor < 0, errno == EEXIST {
      try convergeExistingDatabaseFile(below: directoryDescriptor)
      return
    }
    guard descriptor >= 0 else {
      throw PreparationError.fileSystem(operation: "create database", code: errno)
    }
    defer { Darwin.close(descriptor) }
    try validateAndSecureRegularFile(
      descriptor,
      unsafeError: .unsafeDatabaseFile,
      operation: "secure database"
    )
  }

  private static func convergeExistingDatabaseFile(below directoryDescriptor: Int32) throws {
    let descriptor = databaseFileName.withCString {
      openat(
        directoryDescriptor,
        $0,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
      )
    }
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw PreparationError.unsafeDatabaseFile
      }
      throw PreparationError.fileSystem(operation: "open database", code: errno)
    }
    defer { Darwin.close(descriptor) }
    try validateAndSecureRegularFile(
      descriptor,
      unsafeError: .unsafeDatabaseFile,
      operation: "secure database"
    )
  }

  private static func convergeExistingAuxiliaryFiles(below directoryDescriptor: Int32) throws {
    for suffix in auxiliarySuffixes {
      let name = databaseFileName + suffix
      let descriptor = name.withCString {
        openat(
          directoryDescriptor,
          $0,
          O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
      }
      if descriptor < 0, errno == ENOENT {
        continue
      }
      guard descriptor >= 0 else {
        if errno == ELOOP {
          throw PreparationError.unsafeAuxiliaryFile(suffix)
        }
        throw PreparationError.fileSystem(operation: "open SQLite sidecar", code: errno)
      }
      defer { Darwin.close(descriptor) }
      try validateAndSecureRegularFile(
        descriptor,
        unsafeError: .unsafeAuxiliaryFile(suffix),
        operation: "secure SQLite sidecar"
      )
    }
  }

  private static func convergeExistingStopIntent(below directoryDescriptor: Int32) throws {
    let descriptor = collectionStopIntentFileName.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    if descriptor < 0, errno == ENOENT { return }
    guard descriptor >= 0 else {
      throw PreparationError.unsafeAuxiliaryFile(collectionStopIntentFileName)
    }
    defer { Darwin.close(descriptor) }
    try validateAndSecureRegularFile(
      descriptor, unsafeError: .unsafeAuxiliaryFile(collectionStopIntentFileName),
      operation: "secure collection stop intent")
  }

  private static func validateAndSecureRegularFile(
    _ descriptor: Int32,
    unsafeError: PreparationError,
    operation: String
  ) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw PreparationError.fileSystem(operation: "inspect file", code: errno)
    }
    guard isRegularFile(status), status.st_uid == geteuid(), status.st_nlink == 1 else {
      throw unsafeError
    }
    try removeExtendedACL(descriptor, operation: "remove file ACL")
    guard fchmod(descriptor, ownerFilePermissions) == 0 else {
      throw PreparationError.fileSystem(operation: operation, code: errno)
    }
  }

  private static func isDirectory(_ status: stat) -> Bool {
    status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
  }

  private static func isRegularFile(_ status: stat) -> Bool {
    status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
  }

  private static func isSymbolicLink(_ status: stat) -> Bool {
    status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
  }

  private static func containsExtendedACL(_ descriptor: Int32) throws -> Bool {
    errno = 0
    guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT {
        return false
      }
      throw PreparationError.fileSystem(operation: "read extended ACL", code: errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }

    var entry: acl_entry_t?
    let result = acl_get_entry(
      accessControlList,
      ACL_FIRST_ENTRY.rawValue,
      &entry
    )
    if result == 0 {
      return true
    }
    if errno == EINVAL {
      return false
    }
    guard result >= 0 else {
      throw PreparationError.fileSystem(operation: "inspect extended ACL", code: errno)
    }
    return false
  }

  /// Returns true only when an extended ACL can grant access. Deny-only ACLs
  /// on the system-owned Application Support base are safe to retain because
  /// this code does not own that directory and they can only narrow access.
  private static func containsAccessGrantACL(_ descriptor: Int32) throws -> Bool {
    errno = 0
    guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT {
        return false
      }
      throw PreparationError.fileSystem(operation: "read extended ACL", code: errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }

    var entry: acl_entry_t?
    var entryIdentifier = ACL_FIRST_ENTRY.rawValue
    while true {
      let result = acl_get_entry(accessControlList, entryIdentifier, &entry)
      if result == 0 {
        var tag = ACL_UNDEFINED_TAG
        guard acl_get_tag_type(entry, &tag) == 0 else {
          throw PreparationError.fileSystem(operation: "inspect extended ACL", code: errno)
        }
        guard tag == ACL_EXTENDED_DENY else {
          return true
        }
        entryIdentifier = ACL_NEXT_ENTRY.rawValue
        continue
      }
      if errno == EINVAL {
        return false
      }
      guard result >= 0 else {
        throw PreparationError.fileSystem(operation: "inspect extended ACL", code: errno)
      }
      return false
    }
  }

  private static func removeExtendedACL(
    _ descriptor: Int32,
    operation: String
  ) throws {
    guard try containsExtendedACL(descriptor) else { return }
    guard let emptyAccessControlList = acl_init(0) else {
      throw PreparationError.fileSystem(operation: operation, code: errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(emptyAccessControlList)) }

    guard acl_set_fd_np(descriptor, emptyAccessControlList, ACL_TYPE_EXTENDED) == 0 else {
      throw PreparationError.fileSystem(operation: operation, code: errno)
    }
    guard try !containsExtendedACL(descriptor) else {
      throw PreparationError.fileSystem(operation: operation, code: EACCES)
    }
  }
}
