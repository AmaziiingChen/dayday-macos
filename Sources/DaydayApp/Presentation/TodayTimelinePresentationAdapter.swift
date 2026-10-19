import DaydayCore
import DaydayUnderstanding
import Foundation

enum TodayTimelineFetchState: Equatable, Sendable {
  case loading
  case loaded
  case paused
  case degraded
  case failure
}

enum TodayTimelineState: Equatable, Sendable {
  case loading, empty, paused, permission, degraded, failure, populated
}

enum TodayTimelineItemKind: Equatable, Sendable {
  case boundaryStart, boundaryEnd, activitySegment, sessionSpan, activityInference,
    inferredActivity, objectiveFact, lifecycleGap, securityGap
}

struct TodayActivityDetail: Equatable, Sendable {
  let confidence: ActivityConfidenceBand
  let reviewState: ActivityReviewState
  let rationale: String?
  let eventCount: Int
  let displayLabel: String
}

struct TodayTimelineItem: Identifiable, Equatable, Sendable {
  let id: String
  let occurredAt: Date
  let timeDescription: String
  let endedAt: Date?
  let kind: TodayTimelineItemKind
  let title: String
  let sourceLabel: String
  let accessibilityLabel: String
  var inference: VisualInferenceDigest? = nil
  var activity: TodayActivityDetail? = nil
}

struct TodayTimelinePresentation: Equatable, Sendable {
  let state: TodayTimelineState
  let boundary: WorkdayBoundarySnapshot
  let items: [TodayTimelineItem]
}

/// A pure, read-only projection of closed H1 facts. Application context changes
/// are deterministically grouped into visible local time segments; this is not a
/// durable H2 Session or an inferred Activity.
enum TodayTimelinePresentationAdapter {
  static func make(
    day: DayDescriptor,
    events: [ObjectiveEvent],
    applicationContexts: [EventID: ApplicationContextRecord] = [:],
    collectorStates: [EventID: CollectorStateRecord] = [:],
    visualInferences: [VisibleContentObservation] = [],
    understanding: ObjectiveUnderstandingSnapshot? = nil,
    now: Date,
    fetchState: TodayTimelineFetchState,
    runtime: AppRuntimeSnapshot
  ) -> TodayTimelinePresentation {
    let boundary = day.boundary
    let range = boundary.startsAt..<boundary.endsAt
    let inRangeEvents = events.filter { range.contains($0.occurredAt) }
    let inferenceDigests = VisualInferenceDigestBuilder.make(
      from: visualInferences,
      in: range,
      maximumGap: 5 * 60,
      maximumGroupDuration: 60 * 60,
      maximumObservationsPerGroup: 96
    )
    let formatter = timeFormatter(timeZoneIdentifier: day.timeZoneIdentifier)
    let boundaries = boundaryItems(boundary, now: now, formatter: formatter)
    let state = presentationState(
      fetchState: fetchState,
      runtime: runtime,
      hasDurableContent: !inRangeEvents.isEmpty || !inferenceDigests.isEmpty
    )
    guard state == .populated else {
      return .init(state: state, boundary: boundary, items: boundaries)
    }

    let sortedEvents = inRangeEvents.sorted(by: orderedEarlier)
    let lifecycle = lifecycleItems(
      from: sortedEvents, collectorStates: collectorStates, formatter: formatter)
    let lifecycleEventIDs = Set(lifecycle.map(\.eventID))
    // H2 is optional enrichment. An empty derived snapshot must not hide the durable,
    // objective application timeline after an app restart or before H2 has materialized.
    let hasDerivedSessions = !(understanding?.sessions.isEmpty ?? true)
    let segments =
      hasDerivedSessions
      ? []
      : activitySegments(
        from: sortedEvents,
        applicationContexts: applicationContexts,
        day: day,
        now: now,
        formatter: formatter,
        lifecycleEventIDs: lifecycleEventIDs
      )
    let projected = sortedEvents.compactMap { event -> TodayTimelineItem? in
      if applicationContexts[event.id] != nil,
        event.kind == .applicationContextChanged,
        event.securityDisposition == .allowed
      {
        // The application fact is represented by its enclosing time segment.
        return nil
      }
      if event.kind == .collectorStateTransition {
        // Collector heartbeats and ordinary running/configuration transitions are deliberately
        // absent. Typed state records are projected only by lifecycleItems(_:).
        return nil
      }
      if event.kind == .systemBoundary, event.securityDisposition == .allowed {
        // Legacy allowed system-boundary envelopes do not contain enough typed meaning to claim
        // pause, lock, sleep or recovery in the UI.
        return nil
      }
      if event.securityDisposition != .allowed {
        // Privacy/safety suppressions are still durable evidence and still break application
        // continuity, but their high-frequency implementation reasons do not belong on the
        // primary workday timeline. Only a legacy system boundary with an explicit, human
        // lifecycle meaning is promoted by item(for:).
        let isMeaningfulLegacyBoundary: Bool
        switch event.securityDisposition {
        case .metadataOnly(let reason), .excluded(let reason):
          isMeaningfulLegacyBoundary =
            event.kind == .systemBoundary && systemBoundaryTitle(for: reason) != nil
        case .allowed:
          isMeaningfulLegacyBoundary = false
        }
        guard isMeaningfulLegacyBoundary else { return nil }
      }
      return item(for: event, formatter: formatter)
    }
    let displayLabels = inferenceDisplayLabels(for: inferenceDigests)
    // Keep the intent-level visual narrative even after deterministic Activity/Session
    // projections materialize. The local projections remain independently inspectable evidence;
    // TodayTimelineWindow chooses the compact visual narrative without deleting either layer.
    let inferred = inferenceDigests.map {
      inferenceItem(
        for: $0,
        displayLabel: $0.displayID.flatMap { displayLabels[$0] },
        formatter: formatter,
        timeZoneIdentifier: day.timeZoneIdentifier
      )
    }
    let derived =
      understanding.map {
        understandingItems(
          $0,
          applicationContexts: applicationContexts,
          inferenceDigests: inferenceDigests,
          formatter: formatter
        )
      } ?? []
    let items = (boundaries + segments + lifecycle.map(\.item) + derived + projected + inferred)
      .sorted(by: orderedLatestFirst)
    let hasPrimaryContent = items.contains {
      $0.kind != .boundaryStart && $0.kind != .boundaryEnd
    }
    return .init(
      state:
        hasPrimaryContent
        ? .populated
        : presentationState(fetchState: fetchState, runtime: runtime, hasDurableContent: false),
      boundary: boundary,
      items: items
    )
  }

  private static func understandingItems(
    _ snapshot: ObjectiveUnderstandingSnapshot,
    applicationContexts: [EventID: ApplicationContextRecord],
    inferenceDigests: [VisualInferenceDigest],
    formatter: ISO8601DateFormatter
  ) -> [TodayTimelineItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
    let inferredLabels = Dictionary(
      snapshot.activities.flatMap { activity in
        activity.sessionIDs.map { ($0, applicationLabel(from: activity.title)) }
      },
      uniquingKeysWith: { existing, _ in existing }
    )
    let sessionItems = snapshot.sessions.map { session in
      let application =
        session.objectiveEventIDs.compactMap {
          applicationContexts[$0]?.displayLabelSnapshot
        }.first ?? inferredLabels[session.id] ?? "应用"
      let range =
        "\(formatter.string(from: session.startedAt)) – \(formatter.string(from: session.endedAt))"
      let boundary = session.endingHardBoundary.map { " · 结束于 \($0.rawValue)" } ?? ""
      return TodayTimelineItem(
        id: "session-\(session.id.rawValue.uuidString)",
        occurredAt: session.startedAt,
        timeDescription: displayTimeRange(
          from: session.startedAt, to: session.endedAt,
          timeZoneIdentifier: formatter.timeZone.identifier),
        endedAt: session.endedAt,
        kind: .sessionSpan,
        title: "\(application) 会话",
        sourceLabel: "客观 Session · \(session.objectiveEventIDs.count) 个事实\(boundary)",
        accessibilityLabel:
          "客观会话。应用：\(application)。时段：\(range)。范围：\(sessionScopeLabel(session.scope))。包含 \(session.objectiveEventIDs.count) 个客观事实。"
      )
    }
    let activityItems = snapshot.activities.compactMap { activity -> TodayTimelineItem? in
      let memberSessions = activity.sessionIDs.compactMap { sessionsByID[$0] }
      guard !memberSessions.isEmpty,
        memberSessions.count == activity.sessionIDs.count
      else { return nil }
      let range =
        "\(formatter.string(from: activity.startedAt)) – \(formatter.string(from: activity.endedAt))"
      let title = displayActivityTitle(activity.title)
      let visual =
        inferenceDigests
        .filter {
          $0.startedAt < activity.endedAt
            && ($0.endedAt ?? $0.startedAt) > activity.startedAt
        }
        .max {
          overlapDuration($0, activity: activity) < overlapDuration($1, activity: activity)
        }
      let visualSuffix = visual.map { " · AI 观察 \($0.observationCount) 段" } ?? ""
      return TodayTimelineItem(
        id: "activity-\(activity.id.rawValue.uuidString)",
        occurredAt: activity.startedAt,
        timeDescription: displayTimeRange(
          from: activity.startedAt, to: activity.endedAt,
          timeZoneIdentifier: formatter.timeZone.identifier),
        endedAt: activity.endedAt,
        kind: .activityInference,
        title: title,
        sourceLabel: "本地归集 Activity · \(activity.sessionIDs.count) 个 Session\(visualSuffix)",
        accessibilityLabel:
          "本地归集活动。\(title)。时段：\(range)。可展开核对成员事实。",
        inference: visual,
        activity: TodayActivityDetail(
          confidence: activity.confidence,
          reviewState: activity.reviewState,
          rationale: activity.interpretation.rationale,
          eventCount: memberSessions.reduce(0) { $0 + $1.objectiveEventIDs.count },
          displayLabel: Array(Set(memberSessions.map { sessionScopeLabel($0.scope) }))
            .sorted()
            .joined(separator: "、")
        )
      )
    }
    return activityItems.isEmpty ? sessionItems : activityItems
  }

  private static func overlapDuration(
    _ digest: VisualInferenceDigest,
    activity: Activity
  ) -> TimeInterval {
    let start = max(digest.startedAt, activity.startedAt)
    let end = min(digest.endedAt ?? digest.startedAt, activity.endedAt)
    return max(0, end.timeIntervalSince(start))
  }

  private static func sessionScopeLabel(_ scope: SessionScope) -> String {
    switch scope {
    case .workspace: return "系统前台工作区"
    case .display(let displayID): return displayID.rawValue.uuidString
    }
  }

  private static func applicationLabel(from activityTitle: String) -> String {
    let prefix = "Observed "
    let suffix = " activity"
    guard activityTitle.hasPrefix(prefix), activityTitle.hasSuffix(suffix) else {
      return activityTitle
    }
    return String(activityTitle.dropFirst(prefix.count).dropLast(suffix.count))
  }

  private static func displayActivityTitle(_ storedTitle: String) -> String {
    let label = applicationLabel(from: storedTitle)
    return label == storedTitle ? storedTitle : "使用 \(label)"
  }

  private static func orderedLatestFirst(_ lhs: TodayTimelineItem, _ rhs: TodayTimelineItem) -> Bool
  {
    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
    let lhsRank = kindSortRank(lhs.kind)
    let rhsRank = kindSortRank(rhs.kind)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    if lhs.kind == .inferredActivity, rhs.kind == .inferredActivity,
      lhs.sourceLabel != rhs.sourceLabel
    {
      return lhs.sourceLabel < rhs.sourceLabel
    }
    return lhs.id < rhs.id
  }

  private static func kindSortRank(_ kind: TodayTimelineItemKind) -> Int {
    switch kind {
    case .boundaryStart: 0
    case .securityGap, .lifecycleGap: 1
    case .objectiveFact: 2
    case .activitySegment, .sessionSpan: 3
    case .activityInference, .inferredActivity: 4
    case .boundaryEnd: 5
    }
  }

  private static func orderedEarlier(_ lhs: ObjectiveEvent, _ rhs: ObjectiveEvent) -> Bool {
    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
    return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
  }

  private static func presentationState(
    fetchState: TodayTimelineFetchState,
    runtime: AppRuntimeSnapshot,
    hasDurableContent: Bool
  ) -> TodayTimelineState {
    // Application/window history remains visible after a later Accessibility
    // revocation. A missing screen-recording permission is irrelevant to this
    // collector and must not hide durable application facts.
    if !hasDurableContent, runtime.accessibility == .notAuthorized {
      return .permission
    }
    switch fetchState {
    case .loading: return .loading
    case .paused: return .paused
    case .degraded: return .degraded
    case .failure: return .failure
    case .loaded: return hasDurableContent ? .populated : .empty
    }
  }

  private static func inferenceItem(
    for digest: VisualInferenceDigest,
    displayLabel: String?,
    formatter: ISO8601DateFormatter,
    timeZoneIdentifier: String
  ) -> TodayTimelineItem {
    let count = digest.observationCount > 1 ? " · \(digest.observationCount) 条观察" : ""
    let endDescription = digest.endedAt.map { " 至 \(formatter.string(from: $0))" } ?? ""
    let display = displayLabel.map { " · \($0)" } ?? ""
    return TodayTimelineItem(
      id: digest.id,
      occurredAt: digest.startedAt,
      timeDescription: displayTimeRange(
        from: digest.startedAt, to: digest.endedAt,
        timeZoneIdentifier: timeZoneIdentifier),
      endedAt: digest.endedAt,
      kind: .inferredActivity,
      title: digest.summary,
      sourceLabel: "截图采集时间\(display) · AI 视觉推断\(count)",
      accessibilityLabel:
        "AI 视觉推断。截图采集时间：\(formatter.string(from: digest.startedAt))\(endDescription)。来源：\(displayLabel ?? "未知显示器")。情境：\(digest.summary)。可见交互：\(digest.interaction)。类型：\(digest.activityKind)。",
      inference: digest
    )
  }

  private static func inferenceDisplayLabels(
    for digests: [VisualInferenceDigest]
  ) -> [DisplayID: String] {
    var labels: [DisplayID: String] = [:]
    for digest in digests {
      guard let displayID = digest.displayID, labels[displayID] == nil else { continue }
      labels[displayID] = "屏幕 \(labels.count + 1)"
    }
    return labels
  }

  private static func boundaryItems(
    _ boundary: WorkdayBoundarySnapshot, now: Date, formatter: ISO8601DateFormatter
  ) -> [TodayTimelineItem] {
    var items = [
      TodayTimelineItem(
        id: "boundary-start", occurredAt: boundary.startsAt,
        timeDescription: displayTime(
          boundary.startsAt, timeZoneIdentifier: formatter.timeZone.identifier),
        endedAt: nil,
        kind: .boundaryStart, title: "工作日开始", sourceLabel: "配置边界",
        accessibilityLabel:
          "时间：\(formatter.string(from: boundary.startsAt))。工作日开始，来源：配置边界。配置的工作日起点。"
      )
    ]
    if boundary.endsAt <= now {
      items.append(
        TodayTimelineItem(
          id: "boundary-end", occurredAt: boundary.endsAt,
          timeDescription: displayTime(
            boundary.endsAt, timeZoneIdentifier: formatter.timeZone.identifier),
          endedAt: nil,
          kind: .boundaryEnd, title: "工作日结束", sourceLabel: "配置边界",
          accessibilityLabel:
            "时间：\(formatter.string(from: boundary.endsAt))。工作日结束，来源：配置边界。配置的工作日终点。"
        )
      )
    }
    return items.sorted(by: orderedLatestFirst)
  }

  private static func item(for event: ObjectiveEvent, formatter: ISO8601DateFormatter)
    -> TodayTimelineItem
  {
    let source =
      event.display.map { "显示器 \($0.id.rawValue) · \(event.source.collector.rawValue)" }
      ?? event.source.collector.rawValue
    let kind: TodayTimelineItemKind
    let title: String
    switch event.securityDisposition {
    case .allowed:
      kind = .objectiveFact
      title = "客观事实：\(event.kind.rawValue)"
    case .metadataOnly(let reason), .excluded(let reason):
      if event.kind == .systemBoundary, let boundaryTitle = systemBoundaryTitle(for: reason) {
        kind = .lifecycleGap
        title = boundaryTitle
      } else {
        kind = .securityGap
        title = "隐私或安全间隔：\(reason.rawValue)"
      }
    }
    return .init(
      id: event.id.rawValue.uuidString,
      occurredAt: event.occurredAt,
      timeDescription: displayTime(
        event.occurredAt, timeZoneIdentifier: formatter.timeZone.identifier),
      endedAt: nil,
      kind: kind,
      title: title,
      sourceLabel: source,
      accessibilityLabel:
        "时间：\(formatter.string(from: event.occurredAt))。\(title)，来源：\(source)。"
    )
  }

  private static func activitySegments(
    from events: [ObjectiveEvent],
    applicationContexts: [EventID: ApplicationContextRecord],
    day: DayDescriptor,
    now: Date,
    formatter: ISO8601DateFormatter,
    lifecycleEventIDs: Set<EventID>
  ) -> [TodayTimelineItem] {
    struct OpenSegment {
      let event: ObjectiveEvent
      let context: ApplicationContextRecord
    }

    var open: OpenSegment?
    var segments: [TodayTimelineItem] = []

    func close(_ segment: OpenSegment, at end: Date) {
      guard end > segment.event.occurredAt else { return }
      let duration = durationDescription(from: segment.event.occurredAt, to: end)
      let range =
        "\(formatter.string(from: segment.event.occurredAt)) – \(formatter.string(from: end))"
      let title = "使用 \(segment.context.displayLabelSnapshot)"
      segments.append(
        .init(
          id: "segment-\(segment.event.id.rawValue.uuidString)",
          occurredAt: segment.event.occurredAt,
          timeDescription: displayTimeRange(
            from: segment.event.occurredAt, to: end,
            timeZoneIdentifier: day.timeZoneIdentifier),
          endedAt: end,
          kind: .activitySegment,
          title: title,
          sourceLabel: "本地应用与窗口记录 · \(duration)",
          accessibilityLabel: "\(title)，时段：\(range)，时长：\(duration)。来自本地应用与窗口记录。"
        ))
    }

    for event in events {
      if event.kind == .applicationContextChanged, event.securityDisposition == .allowed {
        if let segment = open { close(segment, at: event.occurredAt) }
        if let context = applicationContexts[event.id] {
          open = .init(event: event, context: context)
        } else {
          // A legacy or unreadable linked projection cannot establish continuity.
          open = nil
        }
      } else if isHardBoundary(event, lifecycleEventIDs: lifecycleEventIDs), let segment = open {
        close(segment, at: event.occurredAt)
        open = nil
      }
    }

    if let open {
      let safeEnd = min(max(now, open.event.occurredAt), day.boundary.endsAt)
      close(open, at: safeEnd)
    }
    return segments
  }

  private static func isHardBoundary(
    _ event: ObjectiveEvent, lifecycleEventIDs: Set<EventID>
  ) -> Bool {
    guard event.securityDisposition == .allowed else { return true }
    return lifecycleEventIDs.contains(event.id)
  }

  private struct LifecycleItem {
    let eventID: EventID
    let item: TodayTimelineItem
  }

  private static func lifecycleItems(
    from events: [ObjectiveEvent],
    collectorStates: [EventID: CollectorStateRecord],
    formatter: ISO8601DateFormatter
  ) -> [LifecycleItem] {
    var priorByCollector: [CollectorKind: CollectorState] = [:]
    var items: [LifecycleItem] = []

    for event in events where event.kind == .collectorStateTransition {
      guard event.securityDisposition == .allowed,
        let record = collectorStates[event.id]
      else { continue }
      let state = record.state
      let prior = priorByCollector[state.kind]
      priorByCollector[state.kind] = state
      guard prior != state,
        let description = lifecycleDescription(current: state, previous: prior)
      else { continue }
      let source = collectorDisplayName(state.kind)
      items.append(
        LifecycleItem(
          eventID: event.id,
          item: TodayTimelineItem(
            id: event.id.rawValue.uuidString,
            occurredAt: event.occurredAt,
            timeDescription: displayTime(
              event.occurredAt, timeZoneIdentifier: formatter.timeZone.identifier),
            endedAt: nil,
            kind: .lifecycleGap,
            title: description,
            sourceLabel: source,
            accessibilityLabel:
              "时间：\(formatter.string(from: event.occurredAt))。\(description)，来源：\(source)。"
          )
        ))
    }
    return items
  }

  private static func lifecycleDescription(
    current: CollectorState, previous: CollectorState?
  ) -> String? {
    if case .paused(let reasons, _) = current.runtime {
      if reasons.contains(.screenLocked) { return "屏幕锁定，记录暂停" }
      if reasons.contains(.systemSleep) { return "系统睡眠，记录暂停" }
      if reasons.contains(.screensAsleep) { return "显示器休眠，记录暂停" }
      if reasons.contains(.userSessionInactive) { return "用户会话离开，记录暂停" }
      if reasons.contains(.globalUserPause) { return "已暂停记录" }
      return nil
    }

    let lostAuthorization =
      current.authorization == .revoked
      || (previous?.authorization.permitsCollection == true
        && !current.authorization.permitsCollection)
    if lostAuthorization { return "系统权限丢失，记录暂停" }

    guard current.authorization.permitsCollection,
      current.runtime == .running,
      let previous,
      isInterrupted(previous)
    else { return nil }
    return "记录已恢复"
  }

  private static func isInterrupted(_ state: CollectorState) -> Bool {
    if !state.authorization.permitsCollection { return true }
    if case .paused(let reasons, _) = state.runtime {
      return !reasons.intersection([
        .globalUserPause, .userSessionInactive, .screensAsleep, .screenLocked, .systemSleep,
      ]).isEmpty
    }
    return false
  }

  private static func collectorDisplayName(_ kind: CollectorKind) -> String {
    switch kind {
    case .screenUnderstanding: "屏幕理解"
    case .applicationWindowContext: "应用与窗口"
    case .chromeContext: "浏览器上下文"
    case .keyboardAggregates: "键盘聚合"
    case .pointerAggregates: "鼠标聚合"
    case .calendar: "日历"
    case .reminders: "提醒事项"
    case .weather: "天气"
    }
  }

  private static func systemBoundaryTitle(
    for reason: CollectionSuppressionReason
  ) -> String? {
    switch reason {
    case .screenLocked: "屏幕锁定，记录暂停"
    case .systemSleep: "系统睡眠，记录暂停"
    case .globalPause: "已暂停记录"
    default: nil
    }
  }

  private static func durationDescription(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分钟" : "\(hours)小时" }
    return "\(max(1, minutes))分钟"
  }

  private static func timeFormatter(timeZoneIdentifier: String) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    return formatter
  }

  private static func displayTime(_ date: Date, timeZoneIdentifier: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: date)
  }

  private static func displayTimeRange(
    from start: Date,
    to end: Date?,
    timeZoneIdentifier: String
  ) -> String {
    guard let end, end > start else {
      return displayTime(start, timeZoneIdentifier: timeZoneIdentifier)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    formatter.dateFormat = "MM-dd HH:mm:ss"
    let startText = formatter.string(from: start)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    if calendar.isDate(start, inSameDayAs: end) {
      formatter.dateFormat = "HH:mm:ss"
    }
    return "\(startText)\n– \(formatter.string(from: end))"
  }
}
