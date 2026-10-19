@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct InteractionHeatmapPresentationTests {
    @Test("Empty input produces a stable empty heatmap")
    func emptyInput() throws {
        let presentation = try InteractionHeatmapPresentationAdapter.make(from: [])

        #expect(presentation.days.isEmpty)
        #expect(presentation.interactionCount == 0)
        #expect(presentation.activeDayCount == 0)
        #expect(presentation.objectiveRecordCount == 0)
    }

    @Test("Hours before 04:00 finish the preceding logical-day row and rows are latest first")
    func aggregatesMultipleLogicalDaysInStableOrder() throws {
        let earlier = try aggregate("2026-08-03T21:00:00Z", zone: "Asia/Shanghai", keyCount: 6)
        let beforeBoundary = try aggregate("2026-08-03T19:00:00Z", zone: "Asia/Shanghai", keyCount: 1)
        let later = try aggregate("2026-08-04T02:00:00Z", zone: "Asia/Shanghai", keyCount: 3)

        let presentation = try InteractionHeatmapPresentationAdapter.make(from: [earlier, beforeBoundary, later])

        #expect(presentation.days.count == 2)
        #expect(presentation.days.map(\.interactionCount) == [9, 1])
        #expect(presentation.days[0].cells.map(\.hour) == Array(4..<24) + Array(0..<4))
        #expect(value(for: 10, in: presentation.days[0]) == 3)
        #expect(value(for: 5, in: presentation.days[0]) == 6)
        #expect(presentation.days[1].cells.last?.hour == 3)
        #expect(presentation.days[1].cells.last?.interactionCount == 1)
        #expect(presentation.activeDayCount == 2)
        #expect(presentation.objectiveRecordCount == 3)
    }

    @Test("DST transition uses civil hour labels without assuming a 24-hour absolute day")
    func handlesSpringAndFallDST() throws {
        let springOne = try aggregate("2026-03-08T06:00:00Z", zone: "America/New_York", keyCount: 1)
        let springThree = try aggregate("2026-03-08T07:00:00Z", zone: "America/New_York", keyCount: 2)
        let fallFirstOne = try aggregate("2026-11-01T05:00:00Z", zone: "America/New_York", keyCount: 3)
        let fallSecondOne = try aggregate("2026-11-01T06:00:00Z", zone: "America/New_York", keyCount: 4)

        let spring = try InteractionHeatmapPresentationAdapter.make(from: [springOne, springThree])
        #expect(value(for: 1, in: spring.days[0]) == 1)
        #expect(value(for: 2, in: spring.days[0]) == 0)
        #expect(value(for: 3, in: spring.days[0]) == 2)

        let fall = try InteractionHeatmapPresentationAdapter.make(from: [fallFirstOne, fallSecondOne])
        let fallOne = try #require(fall.days[0].cells.first(where: { $0.hour == 1 }))
        #expect(fallOne.interactionCount == 7)
        #expect(fallOne.objectiveRecordCount == 2)
    }

    @Test("Unsigned accumulation fails closed instead of wrapping")
    func refusesOverflow() {
        #expect(throws: InteractionHeatmapPresentationAdapter.AggregationError.unsignedOverflow) {
            try InteractionHeatmapPresentationAdapter.checkedAdd(UInt64.max, 1)
        }
    }

    @Test("The current logical day stays visible before it has a checkpoint")
    func includesExpectedLogicalDayWithoutAggregate() throws {
        let start = ISO8601DateFormatter().date(from: "2026-08-12T02:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-08-12T03:00:00Z")!
        let presentation = try InteractionHeatmapPresentationAdapter.make(from: [], in: start..<end)

        let day = try #require(presentation.days.first)
        #expect(day.objectiveRecordCount == 0)
        #expect(day.cells.allSatisfy { !$0.hasAggregate && $0.interactionCount == 0 })
    }

    @Test("Action composition includes keys, clicks, and scroll events")
    func exposesActionComposition() throws {
        let value = try aggregate("2026-08-03T21:00:00Z", zone: "Asia/Shanghai", keyCount: 4, clicks: 2, scrolls: 3)
        let presentation = try InteractionHeatmapPresentationAdapter.make(from: [value])
        let cell = try #require(presentation.days.first?.cells.first(where: { $0.hour == 5 }))

        #expect(cell.keyPressCount == 4)
        #expect(cell.pointerClickCount == 2)
        #expect(cell.scrollActionCount == 3)
        #expect(cell.interactionCount == 9)
    }

    @Test("Robust theme intensity retains visible separation below a busy outlier")
    func activityContrastRetainsOrdinaryHourContrast() {
        let values: [UInt64] = [10, 20, 35, 55, 80, 130, 210, 340, 550, 890, 1_440, 50_000]

        let quiet = ActivityHeatmapContrast.intensity(value: 35, values: values)
        let typical = ActivityHeatmapContrast.intensity(value: 340, values: values)
        let peak = ActivityHeatmapContrast.intensity(value: 50_000, values: values)

        #expect(quiet > 0)
        #expect(typical > quiet)
        #expect(peak == 1)
    }

    private func aggregate(
        _ startValue: String,
        zone: String,
        keyCount: UInt64,
        clicks: UInt64 = 0,
        scrolls: UInt64 = 0
    ) throws -> InputAggregate {
        let start = ISO8601DateFormatter().date(from: startValue)!
        let period = try InputAggregatePeriod(
            start: start,
            end: start.addingTimeInterval(3_600),
            granularity: .hour,
            timeZoneIdentifier: zone
        )
        return try InputAggregate(
            period: period,
            physicalKeyCounts: [PhysicalKeyCount(hardwareKeyCode: 12, count: keyCount)],
            displays: clicks == 0 && scrolls == 0 ? [] : [
                DisplayInputAggregate(
                    display: DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1),
                    pointer: PointerTotals(
                        clicks: ClickCounts(left: clicks),
                        scrollEventCount: scrolls
                    ),
                    grid: try NormalizedDisplayGrid(rows: 1, columns: 1, cells: [])
                )
            ],
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )
    }

    private func value(
        for hour: Int,
        in day: InteractionHeatmapPresentation.Day
    ) -> UInt64? {
        day.cells.first(where: { $0.hour == hour })?.interactionCount
    }
}
