import Foundation

/// Renders a persisted work report into a self-contained Markdown document that includes a bounded
/// front-matter header. Only work-safe identifiers and objective metadata are exported; no journal
/// or mood content can be reached from this type.
public struct WorkReportMarkdownExporter {
  public struct Options: Equatable, Sendable {
    public var includeFrontMatter: Bool
    public var includeSourceReferenceCounts: Bool

    public init(
      includeFrontMatter: Bool = true, includeSourceReferenceCounts: Bool = true
    ) {
      self.includeFrontMatter = includeFrontMatter
      self.includeSourceReferenceCounts = includeSourceReferenceCounts
    }

    public static let standard = Options()
  }

  public init() {}

  public func render(
    _ record: PersistedWorkReportRecord,
    options: Options = .standard
  ) -> String {
    var sections: [String] = []

    if options.includeFrontMatter {
      sections.append(frontMatter(for: record))
    }

    let day = record.day.logicalDate
    sections.append("# 工作日报 · \(Self.dayTitle(day, timeZoneIdentifier: record.day.timeZoneIdentifier))\n")
    sections.append(record.currentRevision.body.trimmingCharacters(in: .whitespacesAndNewlines))

    var footer: [String] = []
    footer.append("- 版本：第 \(record.report.currentRevisionNumber) 版（\(record.currentRevision.origin.rawValue)）")
    footer.append("- 更新时间：\(Self.formatted(record.report.updatedAt))")
    footer.append("- 状态：\(record.report.status == .final ? "已定稿" : "草稿")")
    if let provenance = record.currentRevision.modelProvenance {
      footer.append("- 生成模型：\(provenance.provider) / \(provenance.model)")
    }
    if options.includeSourceReferenceCounts {
      let refs = record.currentRevision.sourceReferences
      footer.append(
        "- 引用：\(refs.activityIDs.count) 项 H2 活动、\(refs.objectiveEventIDs.count) 条客观应用事件、\(refs.workNoteIDs.count) 条工作笔记、\(refs.visibleContentObservationIDs.count) 条视觉观察"
      )
    }
    sections.append(footer.joined(separator: "\n"))

    return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
  }

  public func defaultFilename(
    for record: PersistedWorkReportRecord
  ) -> String {
    let day = record.day.logicalDate
    let date = String(
      format: "%04d-%02d-%02d", day.year, day.month, day.day
    )
    return "Dayday-工作日报-\(date)-v\(record.report.currentRevisionNumber).md"
  }

  private func frontMatter(for record: PersistedWorkReportRecord) -> String {
    let day = record.day.logicalDate
    var yaml: [String] = ["---"]
    yaml.append("title: 工作日报 \(day.year)-\(pad(day.month))-\(pad(day.day))")
    yaml.append("revision: \(record.report.currentRevisionNumber)")
    yaml.append("status: \(record.report.status.rawValue)")
    yaml.append("generatedBy: \(record.day.timeZoneIdentifier)")
    yaml.append("---")
    return yaml.joined(separator: "\n")
  }

  private func pad(_ value: Int) -> String {
    String(format: "%02d", value)
  }

  private static func dayTitle(
    _ day: LogicalDayDate, timeZoneIdentifier: String
  ) -> String {
    String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
  }

  private static func formatted(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}
