import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct MenuBarInsightsPresentationTests {
  @Test("Live input replacement preserves cached application facts")
  func liveInputReplacementPreservesApplicationFacts() {
    let application = ApplicationUsagePresentation.Summary(
      applicationIdentifier: ApplicationIdentifier(rawValue: UUID()),
      displayLabel: "Test App",
      duration: 120,
      intervalCount: 1
    )
    let original = MenuBarInsightsPresentation(
      state: .populated,
      input: .make(aggregates: [], pointerDisplays: []),
      applications: [application],
      applicationSwitchCount: 3,
      hasIncompleteForegroundFacts: true
    )
    let updatedInput = MenuBarInputSummaryPresentation(
      keyPressCount: 8,
      keyboardCounts: [12: 8],
      clickCount: 2,
      scrollActionCount: 1,
      scrollMagnitude: 1,
      hasLegacyScrollMagnitude: false,
      pointerDisplay: nil
    )

    let updated = original.replacingInput(updatedInput, inputIsEmpty: false)

    #expect(updated.input == updatedInput)
    #expect(updated.applications == [application])
    #expect(updated.applicationSwitchCount == 3)
    #expect(updated.hasIncompleteForegroundFacts)
    #expect(updated.state == .populated)
  }

  @Test("Menu-bar input summary totals all displays while retaining one merged heatmap")
  func totalsAllDisplayInput() throws {
    let first = try aggregate(
      start: instant("2026-08-08T08:00:00Z"),
      keyCount: 4,
      clicks: .init(left: 3),
      scroll: .init(up: 2)
    )
    let second = try aggregate(
      start: instant("2026-08-08T09:00:00Z"),
      keyCount: 5,
      clicks: .init(right: 1, other: 2),
      scroll: .init(down: 4, left: 1, right: 2)
    )

    let snapshot = InputInsightsPresentationBuilder.makeRangeSnapshot(
      stored: [first, second], live: []
    )
    let summary = MenuBarInputSummaryPresentation.make(
      aggregates: snapshot.aggregates,
      pointerDisplays: snapshot.pointerDisplays
    )

    #expect(summary.keyPressCount == 9)
    #expect(summary.keyboardCounts[12] == 9)
    #expect(summary.clickCount == 6)
    #expect(summary.scrollActionCount == 0)
    #expect(summary.scrollMagnitude == 9)
    #expect(summary.hasLegacyScrollMagnitude)
    #expect(summary.pointerDisplay != nil)
  }

  private func aggregate(
    start: Date,
    keyCount: UInt64,
    clicks: ClickCounts,
    scroll: ScrollTotals
  ) throws -> InputAggregate {
    let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
    return try InputAggregate(
      period: InputAggregatePeriod(
        start: start,
        end: start.addingTimeInterval(3_600),
        granularity: .hour,
        timeZoneIdentifier: "UTC"
      ),
      physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 12, count: keyCount)],
      displays: [
        DisplayInputAggregate(
          display: display,
          pointer: PointerTotals(clicks: clicks, scroll: scroll),
          grid: try NormalizedDisplayGrid(
            rows: 2,
            columns: 2,
            cells: [NormalizedGridCell(row: 0, column: 0, clicks: clicks)]
          )
        )
      ],
      collectorVersions: ["test-v1"],
      layoutVersions: ["physical-v1"]
    )
  }

  private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
