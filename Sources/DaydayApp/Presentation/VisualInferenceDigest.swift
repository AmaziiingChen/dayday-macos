import DaydayCore
import Foundation

struct VisualInferenceDigest: Identifiable, Equatable, Sendable {
  let id: String
  let startedAt: Date
  let endedAt: Date?
  let summary: String
  let interaction: String
  let activityKind: String
  let evidence: [String]
  let observationCount: Int
  let displayID: DisplayID?
  let observationIDs: [VisibleContentObservationID]
  let foregroundApplicationLabel: String?
  let displayStates: [VisualDisplayState]
  let relationship: VisualDisplayRelationship?
  let systemContextAgreement: VisualSystemContextAgreement
  let uncertainties: [String]

  init(
    id: String,
    startedAt: Date,
    endedAt: Date?,
    summary: String,
    interaction: String,
    activityKind: String,
    evidence: [String],
    observationCount: Int,
    displayID: DisplayID?,
    observationIDs: [VisibleContentObservationID],
    foregroundApplicationLabel: String? = nil,
    displayStates: [VisualDisplayState] = [],
    relationship: VisualDisplayRelationship? = nil,
    systemContextAgreement: VisualSystemContextAgreement = .unavailable,
    uncertainties: [String] = []
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.summary = summary
    self.interaction = interaction
    self.activityKind = activityKind
    self.evidence = evidence
    self.observationCount = observationCount
    self.displayID = displayID
    self.observationIDs = observationIDs
    self.foregroundApplicationLabel = foregroundApplicationLabel
    self.displayStates = displayStates
    self.relationship = relationship
    self.systemContextAgreement = systemContextAgreement
    self.uncertainties = uncertainties
  }

  var reportSummary: String {
    let application = foregroundApplicationLabel.map { "[系统前台应用：\($0)] " } ?? ""
    let displays = displayStates.map { "\($0.role.rawValue)：\($0.visibleState)" }.joined(separator: "；")
    let relationshipLabel = relationship.map { "；跨屏关系：\($0.rawValue)" } ?? ""
    let conflictLabel = systemContextAgreement == .conflicts ? "；系统上下文与画面存在冲突" : ""
    let displayLabel = displays.isEmpty ? "" : "；屏幕：\(displays)"
    return "\(application)[AI 视觉推断] \(summary)；可见交互：\(interaction)\(relationshipLabel)\(conflictLabel)\(displayLabel)"
  }

  func workReportVisualContext() throws -> WorkReportVisualSegmentContext? {
    guard let relationship, !displayStates.isEmpty else { return nil }
    let segment = try VisualWorkSegment(
      primarySituation: summary,
      interaction: interaction,
      activityKind: VisualWorkActivityKind(rawValue: activityKind) ?? .uncertain,
      foregroundApplicationLabel: foregroundApplicationLabel,
      displays: displayStates,
      relationship: relationship,
      systemContextAgreement: systemContextAgreement,
      evidence: evidence,
      uncertainties: uncertainties
    )
    return try WorkReportVisualSegmentContext(
      startedAt: startedAt,
      endedAt: max(endedAt ?? startedAt, startedAt.addingTimeInterval(1)),
      segment: segment,
      observationIDs: observationIDs
    )
  }
}

enum VisualInferenceDigestBuilder {
  private struct Parsed: Sendable {
    let observation: VisibleContentObservation
    let summary: String
    let interaction: String
    let activityKind: String
    let foregroundApplicationLabel: String?
    let evidence: [String]
    let displayStates: [VisualDisplayState]
    let relationship: VisualDisplayRelationship?
    let systemContextAgreement: VisualSystemContextAgreement
    let uncertainties: [String]
  }

  private struct OpenGroup {
    var first: Parsed
    var last: Parsed
    var evidence: [String]
    var observationCount: Int
    var observationIDs: [VisibleContentObservationID]
  }

  static func make(
    from observations: [VisibleContentObservation],
    in range: Range<Date>,
    maximumGap: TimeInterval = 90,
    maximumGroupDuration: TimeInterval = 600,
    maximumObservationsPerGroup: Int = 64
  ) -> [VisualInferenceDigest] {
    precondition(maximumGap >= 0 && maximumGap.isFinite)
    precondition(maximumGroupDuration >= 0 && maximumGroupDuration.isFinite)
    precondition(maximumObservationsPerGroup > 0)
    let parsed =
      observations
      .filter {
        $0.kind == .inference && range.contains($0.provenance.observedAt) && $0.text != nil
      }
      .compactMap(parse)
      .sorted(by: orderedEarlier)

    var groups: [VisualInferenceDigest] = []
    var open: OpenGroup?
    for item in parsed {
      if var current = open,
        canMerge(
          first: current.first,
          last: current.last,
          next: item,
          maximumGap: maximumGap,
          maximumGroupDuration: maximumGroupDuration,
          observationCount: current.observationCount,
          maximumObservationsPerGroup: maximumObservationsPerGroup
        )
      {
        current.last = item
        current.observationCount += 1
        current.observationIDs.append(item.observation.id)
        for evidence in item.evidence where !current.evidence.contains(evidence) {
          if current.evidence.count < 8 { current.evidence.append(evidence) }
        }
        open = current
      } else {
        if let open, let finished = finish(open) { groups.append(finished) }
        open = OpenGroup(
          first: item,
          last: item,
          evidence: Array(item.evidence.prefix(8)),
          observationCount: 1,
          observationIDs: [item.observation.id]
        )
      }
    }
    if let open, let finished = finish(open) { groups.append(finished) }
    return groups
  }

  private static func parse(_ observation: VisibleContentObservation) -> Parsed? {
    if let segment = observation.visualWorkSegment {
      return Parsed(
        observation: observation,
        summary: segment.primarySituation,
        interaction: segment.interaction,
        activityKind: segment.activityKind.rawValue,
        foregroundApplicationLabel: segment.foregroundApplicationLabel,
        evidence: segment.evidence,
        displayStates: segment.displays,
        relationship: segment.relationship,
        systemContextAgreement: segment.systemContextAgreement,
        uncertainties: segment.uncertainties
      )
    }
    guard let text = observation.text else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let summary = bounded(value(after: "情境：", in: lines), maximumUTF8Bytes: 600)
    guard !summary.isEmpty else { return nil }
    let interaction = bounded(
      value(after: "可见交互：", in: lines),
      maximumUTF8Bytes: 600
    )
    let activityKind = bounded(value(after: "类型：", in: lines), maximumUTF8Bytes: 64)
    let foregroundApplicationLabel = bounded(
      value(after: "系统前台应用：", in: lines), maximumUTF8Bytes: 128
    )
    let evidenceStart = lines.firstIndex(where: { $0 == "可见依据：" })
    let evidence =
      evidenceStart.map { index in
        lines.dropFirst(index + 1).compactMap { line -> String? in
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          guard trimmed.hasPrefix("-") else { return nil }
          let value = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
          return value.isEmpty ? nil : bounded(value, maximumUTF8Bytes: 400)
        }
      } ?? []
    return Parsed(
      observation: observation,
      summary: summary,
      interaction: interaction.isEmpty ? "未观察到明确交互" : interaction,
      activityKind: activityKind.isEmpty ? "unknown" : activityKind,
      foregroundApplicationLabel: foregroundApplicationLabel == "未取得" ? nil : foregroundApplicationLabel,
      evidence: evidence,
      displayStates: [],
      relationship: nil,
      systemContextAgreement: .unavailable,
      uncertainties: []
    )
  }

  private static func value(after prefix: String, in lines: [String]) -> String {
    guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return "" }
    return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func orderedEarlier(_ lhs: Parsed, _ rhs: Parsed) -> Bool {
    if lhs.observation.provenance.observedAt != rhs.observation.provenance.observedAt {
      return lhs.observation.provenance.observedAt < rhs.observation.provenance.observedAt
    }
    return lhs.observation.id.rawValue.uuidString < rhs.observation.id.rawValue.uuidString
  }

  private static func canMerge(
    first: Parsed,
    last: Parsed,
    next: Parsed,
    maximumGap: TimeInterval,
    maximumGroupDuration: TimeInterval,
    observationCount: Int,
    maximumObservationsPerGroup: Int
  ) -> Bool {
    intentFamily(last.activityKind) == intentFamily(next.activityKind)
      && intentFamily(last.activityKind) != .uncertain
      && compatibleDisplayScope(last, next)
      && last.relationship != .uncertain
      && next.relationship != .uncertain
      && last.systemContextAgreement != .conflicts
      && next.systemContextAgreement != .conflicts
      && next.observation.provenance.observedAt.timeIntervalSince(
        last.observation.provenance.endedAt ?? last.observation.provenance.observedAt) <= maximumGap
      && (next.observation.provenance.endedAt ?? next.observation.provenance.observedAt)
        .timeIntervalSince(first.observation.provenance.observedAt) <= maximumGroupDuration
      && observationCount < maximumObservationsPerGroup
  }

  private static func compatibleDisplayScope(_ lhs: Parsed, _ rhs: Parsed) -> Bool {
    if lhs.displayStates.isEmpty && rhs.displayStates.isEmpty {
      return lhs.observation.provenance.display?.id == rhs.observation.provenance.display?.id
    }
    return true
  }

  private enum IntentFamily: Equatable {
    case producing, consuming, communicating, meeting, media, other(String), uncertain
  }

  private static func intentFamily(_ kind: String) -> IntentFamily {
    switch kind {
    case "writing", "development": return .producing
    case "reading", "navigation": return .consuming
    case "communication": return .communicating
    case "meeting": return .meeting
    case "media": return .media
    case "uncertain", "unknown": return .uncertain
    default: return .other(kind)
    }
  }

  private static func finish(_ group: OpenGroup) -> VisualInferenceDigest? {
    let startedAt = group.first.observation.provenance.observedAt
    let lastAt = group.last.observation.provenance.endedAt ?? group.last.observation.provenance.observedAt
    // A model response backed by only one instantaneous sample is retained in the archive but is
    // not promoted into a duration card. A later compatible observation can still turn it into a
    // traceable span without inventing elapsed time.
    guard lastAt > startedAt else { return nil }
    return VisualInferenceDigest(
      id: "visual-inference-\(group.first.observation.id.rawValue.uuidString.lowercased())",
      startedAt: startedAt,
      endedAt: lastAt > startedAt ? lastAt : nil,
      summary: group.last.summary,
      interaction: group.last.interaction,
      activityKind: group.last.activityKind,
      evidence: group.evidence,
      observationCount: group.observationCount,
      displayID: group.last.displayStates.count == 1
        ? group.last.displayStates[0].displayID
        : group.last.observation.provenance.display?.id,
      observationIDs: group.observationIDs,
      foregroundApplicationLabel: group.last.foregroundApplicationLabel,
      displayStates: group.last.displayStates,
      relationship: group.last.relationship,
      systemContextAgreement: group.last.systemContextAgreement,
      uncertainties: group.last.uncertainties
    )
  }

  private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
    guard value.utf8.count > maximumUTF8Bytes else { return value }
    var result = ""
    result.reserveCapacity(min(value.count, maximumUTF8Bytes))
    for character in value {
      let candidate = result + String(character)
      guard candidate.utf8.count <= maximumUTF8Bytes else { break }
      result = candidate
    }
    return result
  }
}
