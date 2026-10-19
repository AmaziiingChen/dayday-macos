import Darwin
@testable import DaydayStorage
import Foundation
import Testing

@Suite("Secure production database location")
struct SecureDatabaseLocationTests {
    @Test("prepares an injected Application Support location with owner-only permissions")
    func preparesOwnerOnlyLocation() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )
            let databaseURL = try fileURL(from: location)

            #expect(databaseURL == base
                .appendingPathComponent("Dayday", isDirectory: true)
                .appendingPathComponent("dayday.sqlite3"))
            #expect(try permissions(of: databaseURL.deletingLastPathComponent()) == 0o700)
            #expect(try permissions(of: databaseURL) == 0o600)
            #expect(try fileType(of: databaseURL) == mode_t(S_IFREG))
        }
    }

    @Test("an existing database is secured without changing its bytes")
    func preservesExistingDatabase() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let app = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            try setPermissions(0o755, at: app)
            let database = app.appendingPathComponent("dayday.sqlite3")
            let bytes = Data("existing user database".utf8)
            try bytes.write(to: database, options: .withoutOverwriting)
            try setPermissions(0o644, at: database)

            _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)

            #expect(try Data(contentsOf: database) == bytes)
            #expect(try permissions(of: app) == 0o700)
            #expect(try permissions(of: database) == 0o600)
        }
    }

    @Test("application and database ACLs are removed while bytes are preserved")
    func removesOwnedArtifactACLs() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let app = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            let database = app.appendingPathComponent("dayday.sqlite3")
            let bytes = Data("ACL-protected user data".utf8)
            try bytes.write(to: database, options: .withoutOverwriting)
            try addExtendedACL("everyone allow read,write", at: app)
            try addExtendedACL("everyone allow read,write", at: database)
            #expect(try hasExtendedACL(at: app))
            #expect(try hasExtendedACL(at: database))

            _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)

            #expect(!(try hasExtendedACL(at: app)))
            #expect(!(try hasExtendedACL(at: database)))
            #expect(try Data(contentsOf: database) == bytes)
            #expect(try permissions(of: app) == 0o700)
            #expect(try permissions(of: database) == 0o600)
        }
    }

    @Test("non-file base URLs are rejected without filesystem work")
    func rejectsNonFileURL() throws {
        let url = try #require(URL(string: "https://example.invalid/Application%20Support"))

        #expect(throws: SecureDatabaseLocation.PreparationError.invalidBaseURL) {
            _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: url)
        }
    }

    @Test("a linked base directory is rejected")
    func rejectsLinkedBaseDirectory() throws {
        try withTemporaryRoot { root in
            let realBase = try makeBaseDirectory(in: root)
            let linkedBase = root.appendingPathComponent("linked-support", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedBase,
                withDestinationURL: realBase
            )

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeBaseDirectory) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: linkedBase)
            }
            #expect(!FileManager.default.fileExists(
                atPath: realBase.appendingPathComponent("Dayday").path
            ))
        }
    }

    @Test("an extended ACL on the base is rejected before child creation")
    func rejectsBaseACL() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            try addExtendedACL(
                "everyone allow read,write,file_inherit,directory_inherit",
                at: base
            )
            #expect(try hasExtendedACL(at: base))

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeBaseDirectory) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(!FileManager.default.fileExists(
                atPath: base.appendingPathComponent("Dayday").path
            ))
        }
    }

    @Test("a linked application directory cannot escape the injected base")
    func rejectsLinkedApplicationDirectory() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let linkedApp = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: outside)

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeApplicationDirectory) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(!FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("dayday.sqlite3").path
            ))
        }
    }

    @Test("a linked database target is rejected and never modified")
    func rejectsLinkedDatabase() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let app = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            let outside = root.appendingPathComponent("outside.sqlite3")
            let bytes = Data("must remain untouched".utf8)
            try bytes.write(to: outside, options: .withoutOverwriting)
            try setPermissions(0o644, at: outside)
            try FileManager.default.createSymbolicLink(
                at: app.appendingPathComponent("dayday.sqlite3"),
                withDestinationURL: outside
            )

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeDatabaseFile) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(try Data(contentsOf: outside) == bytes)
            #expect(try permissions(of: outside) == 0o644)
        }
    }

    @Test("a hard-linked database is rejected rather than mutating both names")
    func rejectsHardLinkedDatabase() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let app = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            let original = root.appendingPathComponent("original.sqlite3")
            try Data("hard link".utf8).write(to: original, options: .withoutOverwriting)
            try setPermissions(0o644, at: original)
            let database = app.appendingPathComponent("dayday.sqlite3")
            let result = original.path.withCString { source in
                database.path.withCString { destination in
                    link(source, destination)
                }
            }
            #expect(result == 0)

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeDatabaseFile) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(try permissions(of: original) == 0o644)
            #expect(try Data(contentsOf: original) == Data("hard link".utf8))
        }
    }

    @Test("existing and later SQLite sidecars converge to owner-only permissions")
    func hardensSQLiteSidecars() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let app = base.appendingPathComponent("Dayday", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            let database = app.appendingPathComponent("dayday.sqlite3")
            try Data().write(to: database, options: .withoutOverwriting)
            let wal = URL(fileURLWithPath: database.path + "-wal")
            try Data("wal".utf8).write(to: wal, options: .withoutOverwriting)
            try setPermissions(0o644, at: wal)
            try addExtendedACL("everyone allow read,write", at: wal)

            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )
            #expect(try permissions(of: wal) == 0o600)
            #expect(!(try hasExtendedACL(at: wal)))

            let shm = URL(fileURLWithPath: database.path + "-shm")
            try Data("shm".utf8).write(to: shm, options: .withoutOverwriting)
            try setPermissions(0o644, at: shm)
            try SecureDatabaseLocation.hardenSQLiteArtifacts(at: location)
            #expect(try permissions(of: shm) == 0o600)
        }
    }

    @Test("SQLite rollback journal inherits the secured database mode with a permissive umask")
    func rollbackJournalInheritsDatabaseMode() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )
            let databaseURL = try fileURL(from: location)
            let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")

            try withSQLiteChild(
                databaseURL: databaseURL,
                statements: "BEGIN IMMEDIATE; CREATE TABLE permission_probe(value INTEGER);",
                waitingFor: [journalURL]
            ) {
                let journalPermissions = try permissions(of: journalURL)
                #expect(journalPermissions == 0o600)
            }
        }
    }

    @Test("SQLite WAL and SHM inherit the secured database mode with a permissive umask")
    func walAndShmInheritDatabaseMode() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )
            let databaseURL = try fileURL(from: location)
            let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
            let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")

            try withSQLiteChild(
                databaseURL: databaseURL,
                statements: "PRAGMA journal_mode = WAL; "
                    + "CREATE TABLE permission_probe(value INTEGER); "
                    + "INSERT INTO permission_probe VALUES (1);",
                waitingFor: [walURL, shmURL]
            ) {
                let walPermissions = try permissions(of: walURL)
                let shmPermissions = try permissions(of: shmURL)
                #expect(walPermissions == 0o600)
                #expect(shmPermissions == 0o600)
            }
        }
    }

    @Test("an unsafe sidecar fails closed without touching its target")
    func rejectsLinkedSidecar() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )
            let database = try fileURL(from: location)
            let outside = root.appendingPathComponent("outside-wal")
            try Data("external".utf8).write(to: outside, options: .withoutOverwriting)
            try setPermissions(0o644, at: outside)
            try FileManager.default.createSymbolicLink(
                at: URL(fileURLWithPath: database.path + "-wal"),
                withDestinationURL: outside
            )

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeAuxiliaryFile("-wal")) {
                try SecureDatabaseLocation.hardenSQLiteArtifacts(at: location)
            }
            #expect(try Data(contentsOf: outside) == Data("external".utf8))
            #expect(try permissions(of: outside) == 0o644)
        }
    }

    @Test("a writable shared base is rejected before creating Dayday data")
    func rejectsUnsafeBaseDirectory() throws {
        try withTemporaryRoot { root in
            let base = root.appendingPathComponent("shared", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            try setPermissions(0o777, at: base)

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeBaseDirectory) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(!FileManager.default.fileExists(
                atPath: base.appendingPathComponent("Dayday").path
            ))
        }
    }

    @Test("a deny-only base ACL is allowed because it cannot widen access")
    func allowsDenyOnlyBaseACL() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            try addExtendedACL("everyone deny delete", at: base)

            let location = try SecureDatabaseLocation.prepare(
                baseApplicationSupportURL: base
            )

            #expect(FileManager.default.fileExists(atPath: try fileURL(from: location).path))
        }
    }

    @Test("an allow base ACL is rejected before creating Dayday data")
    func rejectsAccessGrantBaseACL() throws {
        try withTemporaryRoot { root in
            let base = try makeBaseDirectory(in: root)
            try addExtendedACL("everyone allow read", at: base)

            #expect(throws: SecureDatabaseLocation.PreparationError.unsafeBaseDirectory) {
                _ = try SecureDatabaseLocation.prepare(baseApplicationSupportURL: base)
            }
            #expect(!FileManager.default.fileExists(
                atPath: base.appendingPathComponent("Dayday").path
            ))
        }
    }
}

private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dayday-secure-location-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try setPermissions(0o700, at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func makeBaseDirectory(in root: URL) throws -> URL {
    let base = root.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    try setPermissions(0o700, at: base)
    return base
}

private func fileURL(from location: SQLiteDatabaseLocation) throws -> URL {
    switch location {
    case let .file(url):
        return url
    case .inMemory:
        Issue.record("Expected a file-backed database location")
        throw SecureDatabaseLocation.PreparationError.invalidBaseURL
    }
}

private func permissions(of url: URL) throws -> mode_t {
    var status = stat()
    let result = url.path.withCString { lstat($0, &status) }
    guard result == 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test inspect permissions",
            code: errno
        )
    }
    return status.st_mode & 0o777
}

private func fileType(of url: URL) throws -> mode_t {
    var status = stat()
    let result = url.path.withCString { lstat($0, &status) }
    guard result == 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test inspect file type",
            code: errno
        )
    }
    return status.st_mode & mode_t(S_IFMT)
}

private func setPermissions(_ permissions: mode_t, at url: URL) throws {
    let result = url.path.withCString { chmod($0, permissions) }
    guard result == 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test set permissions",
            code: errno
        )
    }
}

private func addExtendedACL(_ entry: String, at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", entry, url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test add extended ACL",
            code: process.terminationStatus
        )
    }
}

private func hasExtendedACL(at url: URL) throws -> Bool {
    let descriptor = url.path.withCString {
        open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test open ACL target",
            code: errno
        )
    }
    defer { Darwin.close(descriptor) }

    errno = 0
    guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return false }
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test read extended ACL",
            code: errno
        )
    }
    defer { acl_free(UnsafeMutableRawPointer(accessControlList)) }
    var aclEntry: acl_entry_t?
    let result = acl_get_entry(
        accessControlList,
        ACL_FIRST_ENTRY.rawValue,
        &aclEntry
    )
    if result == 0 { return true }
    if errno == EINVAL { return false }
    guard result >= 0 else {
        throw SecureDatabaseLocation.PreparationError.fileSystem(
            operation: "test inspect extended ACL",
            code: errno
        )
    }
    return false
}

private enum SQLitePermissionTestError: Error {
    case childFailed(Int32, String)
    case sidecarDidNotAppear
}

private func withSQLiteChild(
    databaseURL: URL,
    statements: String,
    waitingFor sidecarURLs: [URL],
    _ body: () throws -> Void
) throws {
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "umask 000; exec /usr/bin/sqlite3 \"$1\"",
        "dayday-sqlite-permission-test",
        databaseURL.path
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()

    defer {
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("\n.quit\n".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    try input.fileHandleForWriting.write(contentsOf: Data((statements + "\n").utf8))

    let deadline = Date().addingTimeInterval(3)
    while !sidecarURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
        guard process.isRunning, Date() < deadline else {
            throw SQLitePermissionTestError.sidecarDidNotAppear
        }
        usleep(10_000)
    }

    try body()
    try input.fileHandleForWriting.write(contentsOf: Data("\n.quit\n".utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errorData = try errors.fileHandleForReading.readToEnd() ?? Data()
        let message = String(decoding: errorData, as: UTF8.self)
        throw SQLitePermissionTestError.childFailed(process.terminationStatus, message)
    }
}
