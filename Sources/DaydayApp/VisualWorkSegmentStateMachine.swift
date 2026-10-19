import DaydayCore
import Foundation

/// A deterministic local continuity label for diagnostics and evaluation. It deliberately does
/// not turn a model inference into an objective Activity or completion claim.
enum VisualWorkSegmentTransition: String, Equatable, Sendable {
  case opened
  case continued
  case changed
  case uncertain
}

struct VisualWorkSegmentStateMachine: Sendable {
  private struct Previous: Sendable {
    let segment: VisualWorkSegment
    let endedAt: Date
  }

  private static let maximumContinuationGap: TimeInterval = 5 * 60
  private var previous: Previous?

  mutating func record(
    _ segment: VisualWorkSegment,
    startedAt: Date,
    endedAt: Date
  ) -> VisualWorkSegmentTransition {
    defer { previous = Previous(segment: segment, endedAt: endedAt) }
    guard let previous else { return .opened }
    guard segment.activityKind != .uncertain,
      previous.segment.activityKind != .uncertain,
      segment.relationship != .uncertain,
      previous.segment.relationship != .uncertain,
      segment.systemContextAgreement != .conflicts,
      previous.segment.systemContextAgreement != .conflicts
    else { return .uncertain }
    guard startedAt.timeIntervalSince(previous.endedAt) <= Self.maximumContinuationGap else {
      return .opened
    }
    let sameDisplays = Set(segment.displays.map(\.displayID))
      == Set(previous.segment.displays.map(\.displayID))
    let sameSituation = segment.activityKind == previous.segment.activityKind
      && segment.foregroundApplicationLabel == previous.segment.foregroundApplicationLabel
      && segment.relationship == previous.segment.relationship
      && sameDisplays
    return sameSituation ? .continued : .changed
  }
}
