import Foundation

/// The single production composition point for Dayday's durable objective data.
///
/// Both repositories use independently versioned SQLite namespaces inside the
/// owner-only database prepared by `SecureDatabaseLocation`. Keeping location
/// selection here prevents feature code from opening arbitrary files or
/// bypassing link, ACL, and sidecar hardening.
public struct ProductionDataStore: Sendable {
  /// Opening is a process-local composition transaction: path validation,
  /// both namespace migrations, journal-mode convergence, and sidecar
  /// hardening must not inspect or mutate the same files concurrently.
  private static let openLock = NSLock()

  public let objectiveEvents: SQLiteObjectiveEventRepository
  public let inputAggregates: SQLiteInputAggregateRepository
  public let collectionConsents: SQLiteCollectionConsentRepository
  public let collectionStopIntents: CollectionStopIntentStore
  public let workReports: SQLiteWorkReportRepository
  public let deepCaptureArchive: SQLiteDeepCaptureArchiveRepository
  public let sessions: SQLiteSessionRepository
  public let activities: SQLiteActivityRepository
  public let understandingDerivations: SQLiteUnderstandingDerivationRepository
  public let journalEntries: SQLiteJournalEntryRepository
  public let journalFragments: SQLiteJournalFragmentRepository
  public let journalAttachments: SQLiteJournalAttachmentRepository
  public let journalAttachmentFiles: JournalAttachmentFileStore
  public let journalLocationSnapshots: SQLiteJournalLocationSnapshotRepository
  public let healthArchive: SQLiteHealthArchiveRepository
  let location: SQLiteDatabaseLocation
  private let writeabilityProbe: ProductionDatabaseWriteabilityProbe

  private init(
    location: SQLiteDatabaseLocation,
    objectiveEvents: SQLiteObjectiveEventRepository,
    inputAggregates: SQLiteInputAggregateRepository,
    collectionConsents: SQLiteCollectionConsentRepository,
    collectionStopIntents: CollectionStopIntentStore,
    workReports: SQLiteWorkReportRepository,
    deepCaptureArchive: SQLiteDeepCaptureArchiveRepository, sessions: SQLiteSessionRepository,
    activities: SQLiteActivityRepository,
    understandingDerivations: SQLiteUnderstandingDerivationRepository,
    journalEntries: SQLiteJournalEntryRepository,
    journalFragments: SQLiteJournalFragmentRepository,
    journalAttachments: SQLiteJournalAttachmentRepository,
    journalAttachmentFiles: JournalAttachmentFileStore,
    journalLocationSnapshots: SQLiteJournalLocationSnapshotRepository,
    healthArchive: SQLiteHealthArchiveRepository,
    writeabilityProbe: ProductionDatabaseWriteabilityProbe
  ) {
    self.location = location
    self.objectiveEvents = objectiveEvents
    self.inputAggregates = inputAggregates
    self.collectionConsents = collectionConsents
    self.collectionStopIntents = collectionStopIntents
    self.workReports = workReports
    self.deepCaptureArchive = deepCaptureArchive
    self.sessions = sessions
    self.activities = activities
    self.understandingDerivations = understandingDerivations
    self.journalEntries = journalEntries
    self.journalFragments = journalFragments
    self.journalAttachments = journalAttachments
    self.journalAttachmentFiles = journalAttachmentFiles
    self.journalLocationSnapshots = journalLocationSnapshots
    self.healthArchive = healthArchive
    self.writeabilityProbe = writeabilityProbe
  }

  /// Proves that both durable startup boundaries are writable before any producer is admitted.
  /// The SQLite transaction runs on a Storage-owned actor rather than the caller's main actor.
  public func verifyWritable() async throws {
    try Task.checkCancellation()
    try await writeabilityProbe.verifyWritable()
    try Task.checkCancellation()
    try await collectionStopIntents.verifyWritable()
    try Task.checkCancellation()
  }

  /// Prepares and opens the production store at Dayday's owner-only user
  /// Application Support location.
  public static func open() throws -> ProductionDataStore {
    try open(baseApplicationSupportURL: nil)
  }

  /// Test-only composition seam. It remains module-internal so production
  /// feature code cannot select an arbitrary durable-data directory.
  static func open(
    baseApplicationSupportURL: URL
  ) throws -> ProductionDataStore {
    try open(baseApplicationSupportURL: Optional(baseApplicationSupportURL))
  }

  private static func open(
    baseApplicationSupportURL: URL?
  ) throws -> ProductionDataStore {
    try openLock.withLock {
      let location = try SecureDatabaseLocation.prepare(
        baseApplicationSupportURL: baseApplicationSupportURL
      )

      // Open the generic objective namespace first, then the explicitly
      // prefixed aggregate namespace. Each repository validates only its own
      // complete schema and fails closed on partial or modified definitions.
      let objectiveEvents = try SQLiteObjectiveEventRepository(location: location)
      let inputAggregates = try SQLiteInputAggregateRepository(location: location)
      let collectionConsents = try SQLiteCollectionConsentRepository(location: location)
      let workReports = try SQLiteWorkReportRepository(location: location)
      let deepCaptureArchive = try SQLiteDeepCaptureArchiveRepository(location: location)
      let sessions = try SQLiteSessionRepository(location: location)
      let activities = try SQLiteActivityRepository(location: location)
      let understandingDerivations = try SQLiteUnderstandingDerivationRepository(location: location)
      let journalEntries = try SQLiteJournalEntryRepository(location: location)
      let journalFragments = try SQLiteJournalFragmentRepository(location: location)
      let journalAttachments = try SQLiteJournalAttachmentRepository(location: location)
      let journalAttachmentFiles = try JournalAttachmentFileStore(location: location)
      let journalLocationSnapshots = try SQLiteJournalLocationSnapshotRepository(location: location)
      let healthArchive = try SQLiteHealthArchiveRepository(location: location)
      let writeabilityProbe = try ProductionDatabaseWriteabilityProbe(location: location)

      // Opening SQLite may create WAL/SHM files. Re-converge every artifact
      // before handing the store to the application. Keeping this inside the
      // same critical section prevents a transient rollback journal from
      // disappearing between a concurrent scan's open and validation.
      try SecureDatabaseLocation.hardenSQLiteArtifacts(at: location)
      let markerURL = try SecureDatabaseLocation.stopIntentURL(at: location)
      let collectionStopIntents = try CollectionStopIntentStore(markerURL: markerURL)

      return ProductionDataStore(
        location: location,
        objectiveEvents: objectiveEvents,
        inputAggregates: inputAggregates,
        collectionConsents: collectionConsents,
        collectionStopIntents: collectionStopIntents,
        workReports: workReports,
        deepCaptureArchive: deepCaptureArchive, sessions: sessions, activities: activities,
        understandingDerivations: understandingDerivations,
        journalEntries: journalEntries,
        journalFragments: journalFragments,
        journalAttachments: journalAttachments,
        journalAttachmentFiles: journalAttachmentFiles,
        journalLocationSnapshots: journalLocationSnapshots,
        healthArchive: healthArchive,
        writeabilityProbe: writeabilityProbe
      )
    }
  }
}

private actor ProductionDatabaseWriteabilityProbe {
  private let database: SQLiteDatabase

  init(location: SQLiteDatabaseLocation) throws {
    database = try SQLiteDatabase(location: location)
  }

  func verifyWritable() throws {
    try database.verifyProductionStoreWritable()
  }
}
