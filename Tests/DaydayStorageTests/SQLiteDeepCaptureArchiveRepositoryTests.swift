import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite Owner Deep Capture archive", .serialized)
struct SQLiteDeepCaptureArchiveRepositoryTests {
  @Test("round trips visible content and text-production aggregates with idempotency")
  func roundTrip() async throws {
    let repository = try SQLiteDeepCaptureArchiveRepository(location: .inMemory)
    let visible = try VisibleContentObservation(
      provenance: provenance(), kind: .objectiveText, classification: .document,
      redactionState: .redacted, text: "A bounded visible sentence.")
    let aggregate = try TextProductionAggregate(
      provenance: try provenance(end: date("2026-08-03T01:05:00Z")), insertedGraphemeCount: 7,
      insertedUnicodeScalarCount: 7, estimatedWordCount: 4,
      intervals: [
        try TextProductionInterval(
          start: date("2026-08-03T01:00:00Z"), end: date("2026-08-03T01:01:00Z"))
      ])
    #expect(try await repository.insert(visible) == .inserted)
    #expect(try await repository.insert(visible) == .alreadyPresent)
    #expect(try await repository.insert(aggregate) == .inserted)
    let range = date("2026-08-03T01:00:00Z")..<date("2026-08-03T02:00:00Z")
    #expect(try await repository.fetchVisibleContent(observedIn: range) == [visible])
    #expect(try await repository.fetchTextProduction(observedIn: range) == [aggregate])
  }

  @Test("excluded archive records persist only their provenance envelope and zero aggregate")
  func exclusionPersistence() async throws {
    let repository = try SQLiteDeepCaptureArchiveRepository(location: .inMemory)
    let visible = try VisibleContentObservation(
      provenance: provenance(), kind: .objectiveText, redactionState: .excluded,
      suppressionReason: .incognito)
    let aggregate = try TextProductionAggregate(
      provenance: provenance(), suppressionReason: .incognito)
    _ = try await repository.insert(visible)
    _ = try await repository.insert(aggregate)
    let range = date("2026-08-03T01:00:00Z")..<date("2026-08-03T02:00:00Z")
    #expect(try await repository.fetchVisibleContent(observedIn: range).first?.text == nil)
    let stored = try #require(try await repository.fetchTextProduction(observedIn: range).first)
    #expect(stored.insertedGraphemeCount == 0 && stored.intervals.isEmpty)
    #expect(stored.provenance.windowLabel == nil)
    #expect(throws: VisibleContentObservation.ValidationError.exclusionMustUseSafeProvenance) {
      try VisibleContentObservation(
        provenance: try provenance(windowLabel: "Incognito chat"), kind: .objectiveText,
        redactionState: .excluded, suppressionReason: .incognito)
    }
  }

  @Test("created v2 archive reopens with its exact migration fingerprint")
  func backwardOpen() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-deep-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("deep.sqlite"))
    let first = try SQLiteDeepCaptureArchiveRepository(location: location)
    #expect(try await first.schemaVersion() == 3)
    let fingerprint = try await first.schemaFingerprint()
    let reopened = try SQLiteDeepCaptureArchiveRepository(location: location)
    #expect(try await reopened.schemaVersion() == 3)
    #expect(try await reopened.schemaFingerprint() == fingerprint)
  }

  @Test("v1 observations survive the additive visual-usage migration")
  func migratesV1Archive() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-deep-capture-v1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("deep.sqlite")
    let location = SQLiteDatabaseLocation.file(databaseURL)
    let first = try SQLiteDeepCaptureArchiveRepository(location: location)
    let visible = try VisibleContentObservation(
      provenance: provenance(), kind: .objectiveText, classification: .document,
      redactionState: .redacted, text: "Legacy observation")
    _ = try await first.insert(visible)

    let database = try SQLiteDatabase(location: location)
    try database.execute(
      """
      DROP INDEX deep_capture_screen_vision_usage_started_at;
      DROP TABLE deep_capture_screen_vision_usage;
      DROP INDEX deep_capture_screen_vision_pending_evidence_observed_at;
      DROP TABLE deep_capture_screen_vision_pending_evidence;
      DELETE FROM deep_capture_schema_migrations WHERE version = 3;
      DELETE FROM deep_capture_schema_migrations WHERE version = 2;
      UPDATE deep_capture_schema_metadata
      SET schema_version = 1,
          schema_fingerprint = '\(SQLiteDeepCaptureArchiveRepository.legacyV1SchemaFingerprint)'
      WHERE singleton = 1;
      """)
    database.close()

    let migrated = try SQLiteDeepCaptureArchiveRepository(location: location)
    #expect(try await migrated.schemaVersion() == 3)
    #expect(
      try await migrated.fetchVisibleContent(
        observedIn: date("2026-08-03T00:00:00Z")..<date("2026-08-03T02:00:00Z")) == [visible])
    #expect(
      try await migrated.screenVisionUsage(
        in: date("2026-08-03T00:00:00Z")..<date("2026-08-03T02:00:00Z")
      ).callCount == 0)
  }

  @Test("legacy visual confidence remains readable without rewriting the archive")
  func readsLegacyVisualConfidence() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-deep-capture-legacy-visual-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("deep.sqlite"))
    let repository = try SQLiteDeepCaptureArchiveRepository(location: location)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let segment = try VisualWorkSegment(
      primarySituation: "审阅日报生成管线", interaction: "查看时间线记录",
      activityKind: .reading, foregroundApplicationLabel: "Dayday",
      displays: [try .init(displayID: display.id, role: .primary, visibleState: "Dayday 今日界面")],
      relationship: .coordinated, systemContextAgreement: .matches,
      evidence: ["系统前台应用为 Dayday"])
    let observation = try VisibleContentObservation(
      provenance: try VisibleContentProvenance(
        source: CollectorSource(
          collector: .screenUnderstanding, collectorVersion: "byok-screen-vision-timeline-v1",
          payloadSchemaVersion: 4),
        observedAt: date("2026-08-03T01:00:00Z"), timeZoneIdentifier: "UTC", display: display),
      kind: .inference, redactionState: .noRedactionNeeded, text: "视觉推断",
      inferenceOrigin: "byok-screen-vision-timeline-v4", visualWorkSegment: segment)
    _ = try await repository.insert(observation)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let currentPayload = try #require(String(data: encoder.encode(observation), encoding: .utf8))
    let legacyPayload = currentPayload.replacingOccurrences(
      of: "\"activityKind\":\"reading\",\"displays\"",
      with: "\"activityKind\":\"reading\",\"confidence\":0.95,\"displays\"")
    #expect(legacyPayload != currentPayload)
    let database = try SQLiteDatabase(location: location)
    let update = try database.prepare(
      "UPDATE deep_capture_visible_content SET payload = ? WHERE id = ?")
    try update.bind(legacyPayload, at: 1)
    try update.bind(observation.id.rawValue.uuidString.lowercased(), at: 2)
    try update.expectDone()

    let fetched = try await repository.fetchVisibleContent(
      observedIn: date("2026-08-03T00:00:00Z")..<date("2026-08-03T02:00:00Z"))
    #expect(fetched == [observation])

    let tamperedPayload = String(legacyPayload.dropLast()) + ",\"unexpectedLegacyField\":true}"
    let tamper = try database.prepare("UPDATE deep_capture_visible_content SET payload = ? WHERE id = ?")
    try tamper.bind(tamperedPayload, at: 1)
    try tamper.bind(observation.id.rawValue.uuidString.lowercased(), at: 2)
    try tamper.expectDone()
    await #expect(throws: DeepCaptureArchiveStoreError.invalidStoredPayload) {
      _ = try await repository.fetchVisibleContent(
        observedIn: date("2026-08-03T00:00:00Z")..<date("2026-08-03T02:00:00Z"))
    }
    database.close()
  }

  @Test("persists visual call totals and bounded failure categories")
  func visualUsage() async throws {
    let repository = try SQLiteDeepCaptureArchiveRepository(location: .inMemory)
    let start = date("2026-08-03T01:00:00Z")
    let success = try ScreenVisionUsageRecord(
      provider: "dashscope.aliyuncs.com", model: "qwen3-vl-flash", requestID: "request-1",
      startedAt: start, completedAt: start.addingTimeInterval(1), outcome: .success,
      inputTokens: 900, outputTokens: 100, totalTokens: 1_000)
    let failure = try ScreenVisionUsageRecord(
      provider: "dashscope.aliyuncs.com", model: "qwen3-vl-flash",
      startedAt: start.addingTimeInterval(2), completedAt: start.addingTimeInterval(3),
      outcome: .failure, errorCategory: .rateLimited, failureStage: .providerRequest)
    #expect(try await repository.insert(success) == .inserted)
    #expect(try await repository.insert(failure) == .inserted)
    let summary = try await repository.screenVisionUsage(
      in: start..<start.addingTimeInterval(60))
    #expect(summary.callCount == 2)
    #expect(summary.successCount == 1)
    #expect(summary.totalTokens == 1_000)
    #expect(summary.failuresByCategory == [.rateLimited: 1])
    #expect(summary.failuresByStage == [.providerRequest: 1])
  }

  @Test("compressed visual evidence survives reopen until an acknowledged segment removes it")
  func pendingVisualEvidenceQueue() async throws {
    let repository = try SQLiteDeepCaptureArchiveRepository(location: .inMemory)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let first = try ScreenVisionPendingEvidence(
      observedAt: date("2026-08-03T01:00:00Z"), display: display,
      encodedJPEG: Data([0xFF, 0xD8, 0xFF]), pixelWidth: 1_600, pixelHeight: 900,
      redactedOCRLines: [try RedactedOCRLine("日报草稿")]
    )
    let second = try ScreenVisionPendingEvidence(
      observedAt: date("2026-08-03T01:00:10Z"), display: display,
      encodedJPEG: Data([0xFF, 0xD8, 0x00]), pixelWidth: 1_600, pixelHeight: 900,
      redactedOCRLines: []
    )
    #expect(try await repository.insert(second) == .inserted)
    #expect(try await repository.insert(first) == .inserted)
    #expect(try await repository.pendingScreenVisionEvidence(limit: 8) == [first, second])
    try await repository.removePendingScreenVisionEvidence(ids: [first.id])
    #expect(try await repository.pendingScreenVisionEvidence(limit: 8) == [second])

    let fullQueue = try (0..<64).map { index in
      try ScreenVisionPendingEvidence(
        observedAt: date("2026-08-03T01:10:00Z").addingTimeInterval(TimeInterval(index)),
        display: display,
        encodedJPEG: Data([0xFF, 0xD8, UInt8(index)]),
        pixelWidth: 1_600,
        pixelHeight: 900,
        redactedOCRLines: []
      )
    }
    for evidence in fullQueue { _ = try await repository.insert(evidence) }
    try await repository.removePendingScreenVisionEvidence(ids: fullQueue.map(\.id))
    #expect(try await repository.pendingScreenVisionEvidence(limit: 64).isEmpty)
  }

  private func provenance(end: Date? = nil, windowLabel: String? = nil) throws
    -> VisibleContentProvenance
  {
    try VisibleContentProvenance(
      source: CollectorSource(
        collector: .screenUnderstanding, collectorVersion: "1.0.0", payloadSchemaVersion: 1),
      observedAt: date("2026-08-03T01:00:00Z"), endedAt: end, timeZoneIdentifier: "UTC",
      windowLabel: windowLabel)
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
