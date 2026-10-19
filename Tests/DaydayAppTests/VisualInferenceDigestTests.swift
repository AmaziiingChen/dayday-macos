import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@Suite("Visual inference presentation digest")
struct VisualInferenceDigestTests {
  @Test("Parses and groups adjacent inference records without mixing displays")
  func groupsAdjacentRecordsPerDisplay() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let firstDisplay = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let secondDisplay = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let observations = [
      try observation(at: start, display: firstDisplay, summary: "查看项目代码"),
      try observation(
        at: start.addingTimeInterval(30), display: firstDisplay, summary: "继续查看项目代码"),
      try observation(at: start.addingTimeInterval(35), display: secondDisplay, summary: "查阅资料"),
    ]

    let digests = VisualInferenceDigestBuilder.make(
      from: observations,
      in: start..<start.addingTimeInterval(300)
    )

    #expect(digests.count == 2)
    #expect(digests[0].observationCount == 2)
    #expect(digests[0].summary == "继续查看项目代码")
    #expect(digests[0].endedAt == start.addingTimeInterval(60))
    #expect(digests[0].evidence == ["编辑器可见", "代码区域可见"])
    #expect(digests[0].observationIDs == Array(observations.prefix(2).map(\.id)))
    #expect(digests[1].observationCount == 1)
    #expect(digests.allSatisfy { $0.reportSummary.contains("AI 视觉推断") })
  }

  @Test("Today timeline marks inference separately from objective facts")
  func projectsInferenceAsExpandableTimelineItem() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: 1),
      timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400))
    )
    let inference = try observation(
      at: start.addingTimeInterval(60),
      display: DisplayContext(id: DisplayID(), topologyRevision: 1),
      summary: "查看项目时间线"
    )

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [],
      visualInferences: [inference],
      now: start.addingTimeInterval(120),
      fetchState: .loaded,
      runtime: .unknown
    )

    #expect(presentation.state == .populated)
    let item = try #require(presentation.items.first { $0.kind == .inferredActivity })
    #expect(item.inference?.summary == "查看项目时间线")
    #expect(item.sourceLabel.contains("截图采集时间 · 屏幕 1 · AI 视觉推断"))
    #expect(item.timeDescription == "01-01 04:01:00\n– 04:01:30")
    #expect(item.accessibilityLabel.contains("可见交互"))
    #expect(item.accessibilityLabel.contains("截图采集时间"))
  }

  @Test("Today timeline merges compatible minute fragments into a readable work span")
  func todayTimelineCompactsCompatibleVisualFragments() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: 1),
      timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400))
    )
    let observations = [
      try observation(at: start.addingTimeInterval(60), display: display, summary: "查看项目时间线"),
      try observation(at: start.addingTimeInterval(300), display: display, summary: "继续查看项目时间线"),
    ]

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day,
      events: [],
      visualInferences: observations,
      now: start.addingTimeInterval(360),
      fetchState: .loaded,
      runtime: .unknown
    )
    let inferred = presentation.items.filter { $0.kind == .inferredActivity }

    #expect(inferred.count == 1)
    #expect(inferred[0].inference?.observationCount == 2)
    #expect(inferred[0].timeDescription.contains("–"))
  }

  @Test("同一分钟内的视觉记录保留秒级顺序和多屏来源")
  func preservesSecondPrecisionAndDisplayOrder() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let firstDisplay = DisplayContext(
      id: DisplayID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
      topologyRevision: 1)
    let secondDisplay = DisplayContext(
      id: DisplayID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
      topologyRevision: 1)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: 1), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400)))
    let observations = [
      try observation(at: start.addingTimeInterval(41), display: secondDisplay, summary: "第二屏"),
      try observation(at: start.addingTimeInterval(18), display: firstDisplay, summary: "第一屏"),
    ]

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [], visualInferences: observations,
      now: start.addingTimeInterval(60), fetchState: .loaded, runtime: .unknown)
    let items = presentation.items.filter { $0.kind == .inferredActivity }

    #expect(
      items.map(\.timeDescription) == [
        "01-01 04:00:41\n– 04:01:11", "01-01 04:00:18\n– 04:00:48",
      ])
    #expect(items.map(\.sourceLabel).allSatisfy { $0.contains("屏幕") })
    #expect(items[0].sourceLabel.contains("屏幕 2"))
    #expect(items[1].sourceLabel.contains("屏幕 1"))
  }

  @Test("同一秒的多屏记录按稳定屏幕通道排列")
  func ordersSimultaneousDisplaysByStableLane() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let displayA = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let displayB = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let day = try DayDescriptor(
      logicalDate: .init(year: 2024, month: 1, day: 1), timeZoneIdentifier: "UTC",
      boundary: .init(hour: 4, startsAt: start, endsAt: start.addingTimeInterval(86_400)))
    let observations = [
      try observation(at: start.addingTimeInterval(18), display: displayB, summary: "辅助屏"),
      try observation(at: start.addingTimeInterval(18), display: displayA, summary: "主工作屏"),
    ]

    let presentation = TodayTimelinePresentationAdapter.make(
      day: day, events: [], visualInferences: observations,
      now: start.addingTimeInterval(60), fetchState: .loaded, runtime: .unknown)
    let items = presentation.items.filter { $0.kind == .inferredActivity }

    #expect(
      items.map(\.timeDescription) == [
        "01-01 04:00:18\n– 04:00:48", "01-01 04:00:18\n– 04:00:48",
      ])
    #expect(items[0].sourceLabel.contains("屏幕 1"))
    #expect(items[1].sourceLabel.contains("屏幕 2"))
  }

  @Test("Report activity keeps visual inference explicitly uncertain")
  @MainActor
  func enrichesReportActivityWithoutPresentingInferenceAsFact() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let activity = try WorkReportActivityContext(
      id: ActivityID(),
      startedAt: start,
      endedAt: start.addingTimeInterval(300),
      title: "使用 Dayday",
      summary: "来自应用切换的规则推断",
      detectedInteractionSeconds: 0
    )
    let digest = VisualInferenceDigest(
      id: "digest",
      startedAt: start.addingTimeInterval(30),
      endedAt: nil,
      summary: "查看活动时间线",
      interaction: "静态浏览",
      activityKind: "navigation",
      evidence: ["时间线可见"],
      observationCount: 1,
      displayID: nil,
      observationIDs: [VisibleContentObservationID()]
    )

    let enriched = try WorkReportGenerationModel.enrichActivities([activity], with: [digest])

    #expect(enriched.count == 1)
    #expect(enriched[0].summary?.contains("来自应用切换的规则推断") == true)
    #expect(enriched[0].summary?.contains("[AI 视觉推断]") == true)
    #expect(enriched[0].visibleContentObservationIDs == digest.observationIDs)
  }

  @Test("Visual fallback keeps inference provenance without fabricating an objective session")
  @MainActor
  func visualFallbackActivitiesAreBoundedAndExplicitlyLabelled() throws {
    let startedAt = Date(timeIntervalSince1970: 1_785_736_800)
    let firstID = VisibleContentObservationID()
    let secondID = VisibleContentObservationID()
    let digests = [
      VisualInferenceDigest(
        id: "later",
        startedAt: startedAt.addingTimeInterval(60),
        endedAt: nil,
        summary: "查看设计稿",
        interaction: "未观察到明确交互",
        activityKind: "reading",
        evidence: [],
        observationCount: 1,
        displayID: nil,
        observationIDs: [secondID]
      ),
      VisualInferenceDigest(
        id: "earlier",
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(30),
        summary: "编写日报",
        interaction: "输入文本",
        activityKind: "writing",
        evidence: [],
        observationCount: 1,
        displayID: nil,
        observationIDs: [firstID]
      ),
    ]

    let activities = try WorkReportGenerationModel.visualFallbackActivities(
      from: digests, maximumCount: 1)

    #expect(activities.count == 1)
    #expect(activities[0].title == "AI 视觉观察（待核对）")
    #expect(activities[0].summary?.contains("AI 视觉推断") == true)
    #expect(activities[0].visibleContentObservationIDs == [firstID])
    #expect(activities[0].detectedInteractionSeconds == 0)
    #expect(activities[0].startedAt < activities[0].endedAt)
  }

  @Test("Visual fallback samples across the full day instead of using only the morning")
  @MainActor
  func visualFallbackActivitiesSampleEvenlyAcrossTime() throws {
    let startedAt = Date(timeIntervalSince1970: 1_785_736_800)
    let digests = (0..<5).map { offset in
      let observationID = VisibleContentObservationID()
      return VisualInferenceDigest(
        id: "digest-\(offset)",
        startedAt: startedAt.addingTimeInterval(Double(offset) * 3_600),
        endedAt: nil,
        summary: "第 \(offset) 段观察",
        interaction: "静态浏览",
        activityKind: "reading",
        evidence: [],
        observationCount: 1,
        displayID: nil,
        observationIDs: [observationID]
      )
    }

    let activities = try WorkReportGenerationModel.visualFallbackActivities(
      from: digests, maximumCount: 3)

    #expect(
      activities.map(\.startedAt) == [
        startedAt,
        startedAt.addingTimeInterval(7_200),
        startedAt.addingTimeInterval(14_400),
      ])
  }

  @Test("Digest bounds provider text and prevents indefinitely growing groups")
  func boundsUntrustedProviderTextAndGroupDuration() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let oversized = String(repeating: "界", count: 1_000)
    let observations = [
      try observation(at: start, display: display, summary: "第一段"),
      try observation(at: start.addingTimeInterval(570), display: display, summary: oversized),
      try observation(at: start.addingTimeInterval(660), display: display, summary: "第二段"),
    ]

    let digests = VisualInferenceDigestBuilder.make(
      from: observations,
      in: start..<start.addingTimeInterval(900),
      maximumGap: 600,
      maximumGroupDuration: 600
    )

    #expect(digests.count == 2)
    #expect(digests[0].observationCount == 2)
    #expect(digests[0].summary.utf8.count <= 600)
    #expect(digests[1].observationCount == 1)
  }

  @Test("System application facts remain visible in the report-facing digest")
  func preservesSystemApplicationFactAlongsideModelInference() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let observation = try observation(
      at: start,
      display: DisplayContext(id: DisplayID(), topologyRevision: 1),
      summary: "输入一条消息",
      foregroundApplicationLabel: "WeChat"
    )

    let digest = try #require(
      VisualInferenceDigestBuilder.make(
        from: [observation], in: start..<start.addingTimeInterval(60)
      ).first)

    #expect(digest.foregroundApplicationLabel == "WeChat")
    #expect(digest.reportSummary.contains("系统前台应用：WeChat"))
  }

  @Test("A lone point inference remains archived but is not presented as a duration card")
  func suppressesStandaloneZeroDurationCard() throws {
    let start = Date(timeIntervalSince1970: 1_704_081_600)
    let observation = try observation(
      at: start,
      display: DisplayContext(id: DisplayID(), topologyRevision: 1),
      summary: "瞬时切换",
      duration: nil
    )

    let digests = VisualInferenceDigestBuilder.make(
      from: [observation], in: start..<start.addingTimeInterval(60))

    #expect(digests.isEmpty)
  }

  private func observation(
    at date: Date,
    display: DisplayContext,
    summary: String,
    foregroundApplicationLabel: String? = nil,
    duration: TimeInterval? = 30
  ) throws -> VisibleContentObservation {
    let provenance = try VisibleContentProvenance(
      source: CollectorSource(
        collector: .screenUnderstanding,
        collectorVersion: "byok-screen-vision-v1",
        payloadSchemaVersion: 1
      ),
      observedAt: date,
      endedAt: duration.map(date.addingTimeInterval),
      timeZoneIdentifier: "UTC",
      display: display
    )
    return try VisibleContentObservation(
      provenance: provenance,
      kind: .inference,
      redactionState: .noRedactionNeeded,
      text: """
        \(foregroundApplicationLabel.map { "系统前台应用：\($0)\n" } ?? "")情境：\(summary)
        可见交互：静态浏览
        类型：navigation
        置信度：0.90
        可见依据：
        - 编辑器可见
        - 代码区域可见
        """,
      inferenceOrigin: "byok-screen-vision-v1"
    )
  }
}
