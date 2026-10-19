@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct PointerHeatmapPresentationAdapterTests {
    @Test("Mouse heatmap combines completed and live totals across opaque display contexts")
    func combinesHourlyDisplayTotals() throws {
        let firstDisplay = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let secondDisplay = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 2)
        let completed = try aggregate(
            start: instant("2026-08-01T08:00:00Z"),
            display: firstDisplay,
            leftClicks: 3,
            rightClicks: 1,
            dwellMilliseconds: 500
        )
        let live = try aggregate(
            start: instant("2026-08-01T09:00:00Z"),
            display: secondDisplay,
            leftClicks: 2,
            rightClicks: 0,
            dwellMilliseconds: 250
        )

        let presentations = try PointerHeatmapPresentationAdapter.make(from: [completed, live])
        let result = try #require(presentations.first?.display)

        #expect(presentations.count == 1)
        #expect(result.pointer.clicks.left == 5)
        #expect(result.pointer.clicks.right == 1)
        #expect(result.pointer.scrollEventCount == 2)
        #expect(result.grid.cells.first?.clicks.left == 5)
        #expect(result.grid.cells.first?.dwellMilliseconds == 750)
    }

    @Test("Mouse heatmap refuses incompatible grids instead of showing a partial total")
    func rejectsIncompatibleGrids() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let first = try aggregate(
            start: instant("2026-08-01T08:00:00Z"),
            display: display,
            leftClicks: 1,
            rightClicks: 0,
            dwellMilliseconds: 0
        )
        let second = try InputAggregate(
            period: try InputAggregatePeriod(
                start: instant("2026-08-01T09:00:00Z"),
                end: instant("2026-08-01T10:00:00Z"),
                granularity: .hour,
                timeZoneIdentifier: "UTC"
            ),
            displays: [
                DisplayInputAggregate(
                    display: display,
                    pointer: PointerTotals(clicks: ClickCounts(left: 1)),
                    grid: try NormalizedDisplayGrid(rows: 3, columns: 2, cells: [])
                )
            ],
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )

        #expect(throws: PointerHeatmapPresentationAdapter.AggregationError.incompatibleGrid) {
            try PointerHeatmapPresentationAdapter.make(from: [first, second])
        }
    }

    @Test("Long-range heatmap preserves every hourly contribution")
    func combinesLongRangeExactly() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let start = instant("2026-01-01T04:00:00Z")
        let aggregates = try (0..<180).map { offset in
            try aggregate(
                start: start.addingTimeInterval(TimeInterval(offset * 3_600)),
                display: display,
                leftClicks: 1,
                rightClicks: 1,
                dwellMilliseconds: 25
            )
        }

        let result = try #require(
            PointerHeatmapPresentationAdapter.make(from: aggregates).first?.display
        )

        #expect(result.pointer.clicks.left == 180)
        #expect(result.pointer.clicks.right == 180)
        #expect(result.grid.cells.first?.dwellMilliseconds == 4_500)
    }

    @Test("Per-day heatmap groups hourly facts by logical workday")
    func groupsByLogicalDay() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let morning = try aggregate(
            start: instant("2026-08-01T06:00:00Z"),
            display: display,
            leftClicks: 3,
            rightClicks: 1,
            dwellMilliseconds: 500
        )
        let afternoon = try aggregate(
            start: instant("2026-08-01T10:00:00Z"),
            display: display,
            leftClicks: 2,
            rightClicks: 0,
            dwellMilliseconds: 250
        )

        let days = try PointerHeatmapPresentationAdapter.makePerDay(from: [morning, afternoon])
        #expect(days.count == 1)
        let day = try #require(days.first)
        #expect(day.display.pointer.clicks.left == 5)
        #expect(day.display.grid.cells.first?.dwellMilliseconds == 750)
        #expect(day.detectedInteractionMilliseconds == 0) // helper does not set included duration
    }

    @Test("Per-day heatmap keeps daily rollups after hourly retention expires")
    func groupsDailyRollupByLogicalDay() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let daily = try InputAggregate(
            period: try InputAggregatePeriod(
                start: instant("2026-07-01T04:00:00Z"),
                end: instant("2026-07-02T04:00:00Z"),
                granularity: .day,
                timeZoneIdentifier: "UTC",
                workdayBoundaryHour: 4
            ),
            displays: [
                DisplayInputAggregate(
                    display: display,
                    pointer: PointerTotals(clicks: ClickCounts(left: 9)),
                    grid: try NormalizedDisplayGrid(
                        rows: 2, columns: 2,
                        cells: [NormalizedGridCell(row: 0, column: 0, clicks: ClickCounts(left: 9))]
                    )
                )
            ],
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )
        let days = try PointerHeatmapPresentationAdapter.makePerDay(from: [daily])
        #expect(days.count == 1)
        #expect(days.first?.display.pointer.clicks.left == 9)
        #expect(days.first?.logicalDayStart == instant("2026-07-01T04:00:00Z"))
    }

    @Test("Per-day heatmap keeps separate logical days apart")
    func separatesLogicalDays() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let dayOne = try aggregate(
            start: instant("2026-07-31T06:00:00Z"),
            display: display,
            leftClicks: 4,
            rightClicks: 0,
            dwellMilliseconds: 100
        )
        let dayTwo = try aggregate(
            start: instant("2026-08-01T06:00:00Z"),
            display: display,
            leftClicks: 1,
            rightClicks: 0,
            dwellMilliseconds: 200
        )

        let days = try PointerHeatmapPresentationAdapter.makePerDay(from: [dayOne, dayTwo])
        #expect(days.count == 2)
        let ordered = try #require(days.max(by: { $0.logicalDayStart < $1.logicalDayStart }))
        #expect(ordered.logicalDayStart == instant("2026-08-01T04:00:00Z"))
    }

    @Test("Per-day heatmap rejects incompatible grids within a day")
    func rejectsIncompatibleGridWithinDay() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let first = try aggregate(
            start: instant("2026-08-01T06:00:00Z"),
            display: display,
            leftClicks: 1,
            rightClicks: 0,
            dwellMilliseconds: 0
        )
        let second = try InputAggregate(
            period: try InputAggregatePeriod(
                start: instant("2026-08-01T07:00:00Z"),
                end: instant("2026-08-01T08:00:00Z"),
                granularity: .hour,
                timeZoneIdentifier: "UTC"
            ),
            displays: [
                DisplayInputAggregate(
                    display: display,
                    pointer: PointerTotals(clicks: ClickCounts(left: 1)),
                    grid: try NormalizedDisplayGrid(rows: 3, columns: 2, cells: [])
                )
            ],
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )

        #expect(throws: PointerHeatmapPresentationAdapter.AggregationError.incompatibleGrid) {
            try PointerHeatmapPresentationAdapter.makePerDay(from: [first, second])
        }
    }

    private func aggregate(
        start: Date,
        display: DisplayContext,
        leftClicks: UInt64,
        rightClicks: UInt64,
        dwellMilliseconds: UInt64
    ) throws -> InputAggregate {
        let period = try InputAggregatePeriod(
            start: start,
            end: start.addingTimeInterval(3_600),
            granularity: .hour,
            timeZoneIdentifier: "UTC"
        )
        return try InputAggregate(
            period: period,
            displays: [
                DisplayInputAggregate(
                    display: display,
                    pointer: PointerTotals(
                        clicks: ClickCounts(left: leftClicks, right: rightClicks),
                        scroll: ScrollTotals(up: 2),
                        scrollEventCount: 1
                    ),
                    grid: try NormalizedDisplayGrid(
                        rows: 2,
                        columns: 2,
                        cells: [
                            NormalizedGridCell(
                                row: 0,
                                column: 0,
                                clicks: ClickCounts(left: leftClicks, right: rightClicks),
                                dwellMilliseconds: dwellMilliseconds
                            )
                        ]
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
