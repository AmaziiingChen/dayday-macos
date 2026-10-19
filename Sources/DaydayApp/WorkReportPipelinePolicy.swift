import DaydayCore
import Foundation

struct WorkReportEvidenceCoverage: Equatable, Sendable {
  /// Five-to-eight-minute observation windows need bounded provider/archive time before a report
  /// can fairly call them stale. This is a generation gate, not a model service-level claim.
  static let visualFreshnessTolerance: TimeInterval = 10 * 60
  static let lateRevisionQuiescence: TimeInterval = 10 * 60

  let objectiveObservationCount: Int
  let visualInferenceObservationCount: Int
  let availableVisualSegmentCount: Int
  let includedVisualSegmentCount: Int
  let latestObjectiveObservedAt: Date?
  let latestVisualInferredAt: Date?

  static let empty = WorkReportEvidenceCoverage(
    objectiveObservationCount: 0,
    visualInferenceObservationCount: 0,
    availableVisualSegmentCount: 0,
    includedVisualSegmentCount: 0,
    latestObjectiveObservedAt: nil,
    latestVisualInferredAt: nil
  )

  var visualLag: TimeInterval? {
    guard let latestObjectiveObservedAt, let latestVisualInferredAt else { return nil }
    return latestObjectiveObservedAt.timeIntervalSince(latestVisualInferredAt)
  }

  var latestEvidenceAt: Date? {
    [latestObjectiveObservedAt, latestVisualInferredAt].compactMap { $0 }.max()
  }

  func isQuiescent(at now: Date, additionalEvidenceAt: Date? = nil) -> Bool {
    guard let latest = [latestEvidenceAt, additionalEvidenceAt].compactMap({ $0 }).max()
    else { return true }
    return now.timeIntervalSince(latest) >= Self.lateRevisionQuiescence
  }

  var blocksGeneration: Bool {
    guard objectiveObservationCount > 0 else { return false }
    guard visualInferenceObservationCount > 0, let visualLag else { return true }
    return visualLag > Self.visualFreshnessTolerance
  }

  var statusText: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    let objective = latestObjectiveObservedAt.map(formatter.string) ?? "无"
    let visual = latestVisualInferredAt.map(formatter.string) ?? "无"
    let included =
      availableVisualSegmentCount == includedVisualSegmentCount
      ? "\(includedVisualSegmentCount) 段"
      : "\(includedVisualSegmentCount)/\(availableVisualSegmentCount) 段"
    return "客观画面到 \(objective)；视觉总结到 \(visual)；提交 \(included)"
  }

  var blockingStatusText: String {
    if visualInferenceObservationCount == 0 {
      return "视觉总结尚未就绪，正在等待补齐"
    }
    let minutes = max(1, Int((visualLag ?? 0) / 60))
    return "视觉总结延迟约 \(minutes) 分钟，正在等待更新"
  }
}

enum WorkReportPipelinePolicy {
  static let maximumReportVisualSegments = 36

  static func visualSnapshot(
    from observations: [VisibleContentObservation],
    in range: Range<Date>
  ) throws -> (segments: [WorkReportVisualSegmentContext], coverage: WorkReportEvidenceCoverage) {
    let allDigests = VisualInferenceDigestBuilder.make(
      from: observations,
      in: range,
      maximumGap: 5 * 60,
      maximumGroupDuration: 60 * 60,
      maximumObservationsPerGroup: 96
    )
    let selected = evenlySampled(allDigests, maximumCount: maximumReportVisualSegments)
    let segments = try selected.compactMap(compactVisualContext)
    let objective = observations.filter {
      $0.kind == .objectiveText && $0.text != nil && range.contains($0.provenance.observedAt)
    }
    let inference = observations.filter {
      $0.kind == .inference && $0.text != nil && range.contains($0.provenance.observedAt)
    }
    return (
      segments,
      WorkReportEvidenceCoverage(
        objectiveObservationCount: objective.count,
        visualInferenceObservationCount: inference.count,
        availableVisualSegmentCount: allDigests.count,
        includedVisualSegmentCount: segments.count,
        latestObjectiveObservedAt: objective.map(\.provenance.observedAt).max(),
        latestVisualInferredAt: inference.map {
          $0.provenance.endedAt ?? $0.provenance.observedAt
        }.max()
      )
    )
  }

  static func objectiveApplicationSegments(
    _ segments: [WorkReportObjectiveApplicationSegment],
    maximumCount: Int = 72
  ) -> [WorkReportObjectiveApplicationSegment] {
    precondition(maximumCount > 0)
    let compacted = compactObjectiveApplicationSegments(segments)
    guard compacted.count > maximumCount else { return compacted }
    return evenlySampled(compacted, maximumCount: maximumCount)
  }

  /// Accessibility can emit repeated notifications for an unchanged app/window. Preserve every
  /// EventID as provenance while presenting and submitting one deterministic continuous span.
  private static func compactObjectiveApplicationSegments(
    _ segments: [WorkReportObjectiveApplicationSegment]
  ) -> [WorkReportObjectiveApplicationSegment] {
    let ordered = segments.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.endedAt < $1.endedAt
    }
    var result: [WorkReportObjectiveApplicationSegment] = []
    for segment in ordered {
      guard let previous = result.last,
        previous.applicationLabel == segment.applicationLabel,
        previous.windowTitle == segment.windowTitle,
        previous.documentFilenameHint == segment.documentFilenameHint,
        segment.startedAt.timeIntervalSince(previous.endedAt) <= 2
      else {
        result.append(segment)
        continue
      }
      let identifiers = previous.objectiveEventIDs + segment.objectiveEventIDs.filter {
        !previous.objectiveEventIDs.contains($0)
      }
      guard let merged = try? WorkReportObjectiveApplicationSegment(
        startedAt: previous.startedAt,
        endedAt: max(previous.endedAt, segment.endedAt),
        applicationLabel: previous.applicationLabel,
        windowTitle: previous.windowTitle,
        documentFilenameHint: previous.documentFilenameHint,
        objectiveEventIDs: identifiers
      ) else {
        result.append(segment)
        continue
      }
      result[result.count - 1] = merged
    }
    return result
  }

  static func workNoteAdvisory(for note: String) -> String? {
    let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    let hasLetter = normalized.unicodeScalars.contains {
      CharacterSet.letters.contains($0)
    }
    if !hasLetter || normalized.count < 4 {
      return "这条工作笔记可能缺少可总结的语义；仍会按原文提交，不会自动改写或丢弃"
    }
    return nil
  }

  private static func compactVisualContext(
    _ digest: VisualInferenceDigest
  ) throws -> WorkReportVisualSegmentContext? {
    guard let relationship = digest.relationship, !digest.displayStates.isEmpty else { return nil }
    let segment = try VisualWorkSegment(
      primarySituation: bounded(digest.summary, maximumUTF8Bytes: 480),
      interaction: bounded(digest.interaction, maximumUTF8Bytes: 320),
      activityKind: VisualWorkActivityKind(rawValue: digest.activityKind) ?? .uncertain,
      foregroundApplicationLabel: digest.foregroundApplicationLabel,
      displays: digest.displayStates,
      relationship: relationship,
      systemContextAgreement: digest.systemContextAgreement,
      evidence: Array(digest.evidence.prefix(3)).map {
        bounded($0, maximumUTF8Bytes: 192)
      },
      uncertainties: Array(digest.uncertainties.prefix(2)).map {
        bounded($0, maximumUTF8Bytes: 192)
      }
    )
    return try WorkReportVisualSegmentContext(
      startedAt: digest.startedAt,
      endedAt: max(digest.endedAt ?? digest.startedAt, digest.startedAt.addingTimeInterval(1)),
      segment: segment,
      observationIDs: digest.observationIDs
    )
  }

  private static func evenlySampled<Value>(
    _ values: [Value], maximumCount: Int
  ) -> [Value] {
    precondition(maximumCount > 0)
    guard values.count > maximumCount else { return values }
    guard maximumCount > 1 else { return [values[0]] }
    return (0..<maximumCount).map { index in
      values[index * (values.count - 1) / (maximumCount - 1)]
    }
  }

  private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
    guard value.utf8.count > maximumUTF8Bytes else { return value }
    var result = ""
    for character in value {
      let candidate = result + String(character)
      guard candidate.utf8.count <= maximumUTF8Bytes else { break }
      result = candidate
    }
    return result
  }
}
