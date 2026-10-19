import Foundation
import Testing

@testable import DaydayCore

@Suite("Model usage and persisted work report contracts")
struct ModelUsageTests {
  @Test("successful work-report usage is linked to its exact revision")
  func successfulUsageLinkage() throws {
    let record = try makeRecord()

    #expect(record.modelUsage?.revisionID == record.currentRevision.id)
    #expect(record.modelUsage?.task == .workReport)
    #expect(record.modelUsage?.totalTokens == 15)
  }

  @Test("success requires a revision and failure requires a bounded error class")
  func outcomeValidation() {
    #expect(throws: ModelUsage.ValidationError.successfulAttemptRequiresRevision) {
      try ModelUsage(
        revisionID: nil,
        requestID: nil,
        provider: "deepseek",
        model: "deepseek-v4-flash",
        task: .workReport,
        startedAt: Date(timeIntervalSinceReferenceDate: 1),
        completedAt: Date(timeIntervalSinceReferenceDate: 2),
        outcome: .success
      )
    }
    #expect(throws: ModelUsage.ValidationError.failedAttemptRequiresError) {
      try ModelUsage(
        revisionID: nil,
        requestID: nil,
        provider: "deepseek",
        model: "deepseek-v4-flash",
        task: .workReport,
        startedAt: Date(timeIntervalSinceReferenceDate: 1),
        completedAt: Date(timeIntervalSinceReferenceDate: 2),
        outcome: .failure
      )
    }
  }

  @Test("markdown export renders front matter, body, and bounded metadata")
  func markdownExport() throws {
    let record = try makeRecord()
    let exporter = WorkReportMarkdownExporter()
    let output = exporter.render(record)

    #expect(output.hasPrefix("---"))
    #expect(output.contains("revision: 1"))
    #expect(output.contains("status: draft"))
    #expect(output.contains("完成了真实日报持久化。"))
    #expect(output.contains("- 版本：第 1 版（model）"))
    #expect(output.contains("- 生成模型：deepseek / deepseek-v4-flash"))

    let name = exporter.defaultFilename(for: record)
    #expect(name.hasSuffix(".md"))
    #expect(name.contains("工作日报"))
    #expect(name.contains("-v1"))
  }

  @Test("markdown export omits front matter when disallowed")
  func markdownExportWithoutFrontMatter() throws {
    let record = try makeRecord()
    let exporter = WorkReportMarkdownExporter()
    let output = exporter.render(record, options: .init(includeFrontMatter: false))

    #expect(output.hasPrefix("# 工作日报"))
    #expect(!output.contains("revision:"))
  }

  private func makeRecord() throws -> PersistedWorkReportRecord {
    let reportID = WorkReportID()
    let createdAt = Date(timeIntervalSinceReferenceDate: 100)
    let day = try makeDay(at: createdAt)
    let revision = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: 1,
      previousRevisionID: nil,
      body: "完成了真实日报持久化。",
      origin: .model,
      modelProvenance: try ModelProvenance(
        provider: "deepseek",
        model: "deepseek-v4-flash",
        promptVersion: "work-report-v1"
      ),
      createdAt: createdAt
    )
    let report = try WorkReport(
      id: reportID,
      dayID: day.id,
      initialRevision: revision,
      createdAt: createdAt
    )
    let usage = try ModelUsage(
      revisionID: revision.id,
      requestID: "request-1",
      provider: "deepseek",
      model: "deepseek-v4-flash",
      task: .workReport,
      startedAt: createdAt,
      completedAt: createdAt,
      outcome: .success,
      inputTokens: 10,
      outputTokens: 5,
      totalTokens: 15
    )
    return try PersistedWorkReportRecord(
      day: day,
      report: report,
      currentRevision: revision,
      modelUsage: usage
    )
  }

  private func makeDay(at date: Date) throws -> DayDescriptor {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let policy = WorkdayBoundary.standard
    let start = try policy.start(containing: date, calendar: calendar)
    let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    return try DayDescriptor(
      logicalDate: .init(
        year: try #require(components.year),
        month: try #require(components.month),
        day: try #require(components.day)
      ),
      timeZoneIdentifier: "UTC",
      boundary: .init(hour: policy.hour, startsAt: start, endsAt: end)
    )
  }
}
