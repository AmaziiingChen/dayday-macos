import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct VisualWorkSegmentStateMachineTests {
  @Test
  func preservesACompatibleVisibleWorkSegment() throws {
    var machine = VisualWorkSegmentStateMachine()
    let start = Date(timeIntervalSinceReferenceDate: 2_000)
    let first = try segment(activity: .writing, application: "WeChat", display: DisplayID())

    #expect(machine.record(first, startedAt: start, endedAt: start.addingTimeInterval(20)) == .opened)
    #expect(
      machine.record(
        try segment(activity: .writing, application: "WeChat", display: first.displays[0].displayID),
        startedAt: start.addingTimeInterval(30),
        endedAt: start.addingTimeInterval(45)
      ) == .continued
    )
  }

  @Test
  func splitsChangedOrUncertainVisualWork() throws {
    var machine = VisualWorkSegmentStateMachine()
    let start = Date(timeIntervalSinceReferenceDate: 3_000)
    let first = try segment(activity: .writing, application: "WeChat", display: DisplayID())
    _ = machine.record(first, startedAt: start, endedAt: start.addingTimeInterval(10))

    #expect(
      machine.record(
        try segment(activity: .development, application: "Xcode", display: first.displays[0].displayID),
        startedAt: start.addingTimeInterval(20), endedAt: start.addingTimeInterval(30)
      ) == .changed
    )
    #expect(
      machine.record(
        try segment(activity: .uncertain, application: "Xcode", display: first.displays[0].displayID),
        startedAt: start.addingTimeInterval(40), endedAt: start.addingTimeInterval(50)
      ) == .uncertain
    )
  }

  @Test
  func marksAContextConflictAsUncertainInsteadOfContinuingIt() throws {
    var machine = VisualWorkSegmentStateMachine()
    let start = Date(timeIntervalSinceReferenceDate: 4_000)
    let first = try segment(activity: .writing, application: "WeChat", display: DisplayID())
    _ = machine.record(first, startedAt: start, endedAt: start.addingTimeInterval(10))

    let conflict = try VisualWorkSegment(
      primarySituation: "相似聊天界面",
      interaction: "输入区域可见",
      activityKind: .communication,
      foregroundApplicationLabel: "WeChat",
      displays: first.displays,
      relationship: .coordinated,
      systemContextAgreement: .conflicts,
      evidence: ["聊天窗口可见"],
      uncertainties: ["系统应用与画面身份不一致"]
    )
    #expect(
      machine.record(
        conflict, startedAt: start.addingTimeInterval(20), endedAt: start.addingTimeInterval(30)
      ) == .uncertain
    )
  }

  private func segment(
    activity: VisualWorkActivityKind,
    application: String,
    display: DisplayID
  ) throws -> VisualWorkSegment {
    try VisualWorkSegment(
      primarySituation: "可见工作状态",
      interaction: "画面中的编辑状态",
      activityKind: activity,
      foregroundApplicationLabel: application,
      displays: [try .init(displayID: display, role: .primary, visibleState: "主要工作窗口")],
      relationship: activity == .uncertain ? .uncertain : .coordinated,
      evidence: ["可见应用内容"]
    )
  }
}
