@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct ApplicationInputDetailPresentationTests {
    @Test("Combines persisted application summaries and coarse input totals without replayable detail")
    func combinesApplicationDetails() throws {
        let editor = ApplicationIdentifier(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let browser = ApplicationIdentifier(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let usage = ApplicationUsagePresentation(
            state: .populated,
            intervals: [
                .init(
                    id: "editor",
                    applicationIdentifier: editor,
                    displayLabel: "编辑器",
                    startedAt: instant("2026-08-01T08:00:00Z"),
                    endedAt: instant("2026-08-01T08:15:00Z"),
                    isOngoing: false
                ),
                .init(
                    id: "browser",
                    applicationIdentifier: browser,
                    displayLabel: "浏览器",
                    startedAt: instant("2026-08-01T08:15:00Z"),
                    endedAt: instant("2026-08-01T08:25:00Z"),
                    isOngoing: false
                ),
            ],
            summaries: [
                .init(applicationIdentifier: editor, displayLabel: "编辑器", duration: 900, intervalCount: 2),
                .init(applicationIdentifier: browser, displayLabel: "浏览器", duration: 600, intervalCount: 1),
            ],
            observedRangeDuration: 1_600,
            applicationSwitchCount: 2
        )
        let first = try aggregate(
            "2026-08-01T08:00:00Z",
            inputs: [
                .init(applicationIdentifier: editor, keyCount: 12, pointer: .init(clicks: .init(left: 2), scroll: .init(up: 3), scrollEventCount: 3)),
                .init(applicationIdentifier: browser, keyCount: 4, pointer: .init(clicks: .init(right: 1), scroll: .init(down: 2), scrollEventCount: 2)),
            ]
        )
        let second = try aggregate(
            "2026-08-01T09:00:00Z",
            inputs: [.init(applicationIdentifier: editor, keyCount: 8, pointer: .init(clicks: .init(other: 1)))]
        )

        let result = try ApplicationInputDetailPresentationAdapter.make(
            applicationUsage: usage,
            inputAggregates: [first, second]
        )

        #expect(result.state == .populated)
        #expect(result.foregroundDuration == 1_500)
        #expect(result.noForegroundFactDuration == 100)
        #expect(result.applicationSwitchCount == 2)
        #expect(result.input == .init(keyCount: 24, clickCount: 4, scrollCount: 5))
        #expect(result.applications.map(\.applicationIdentifier) == [editor, browser])
        #expect(result.applications[0].displayLabel == "编辑器")
        #expect(result.applications[0].input == .init(keyCount: 20, clickCount: 3, scrollCount: 3))
    }

    @Test("Missing foreground context is explicit partial state without calling it idle")
    func reportsPartialForegroundFacts() throws {
        let application = ApplicationIdentifier(rawValue: UUID())
        let usage = ApplicationUsagePresentation(
            state: .empty,
            intervals: [],
            summaries: [],
            observedRangeDuration: 600,
            hasIncompleteForegroundFacts: true
        )
        let aggregate = try aggregate(
            "2026-08-01T08:00:00Z",
            inputs: [.init(applicationIdentifier: application, keyCount: 1)]
        )

        let result = try ApplicationInputDetailPresentationAdapter.make(
            applicationUsage: usage,
            inputAggregates: [aggregate]
        )

        #expect(result.state == .partial)
        #expect(result.foregroundDuration == 0)
        #expect(result.noForegroundFactDuration == 600)
        #expect(result.applications[0].displayLabel == nil)
    }

    @Test("Global physical and display totals remain visible without per-application input attribution")
    func combinesUnattributedGlobalInput() throws {
        let display = DisplayContext(id: DisplayID(rawValue: UUID()), topologyRevision: 1)
        let aggregate = try InputAggregate(
            period: try InputAggregatePeriod(
                start: instant("2026-08-01T08:00:00Z"),
                end: instant("2026-08-01T09:00:00Z"),
                granularity: .hour,
                timeZoneIdentifier: "UTC"
            ),
            physicalKeyCounts: [
                .init(hardwareKeyCode: 0, count: 12),
                .init(hardwareKeyCode: 1, count: 7),
            ],
            displays: [
                .init(
                    display: display,
                    pointer: .init(
                        clicks: .init(left: 3, right: 2, other: 1),
                        scroll: .init(up: 4, down: 2, left: 1),
                        scrollEventCount: 7
                    ),
                    grid: try .init(rows: 2, columns: 2, cells: [])
                )
            ],
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )

        let result = try ApplicationInputDetailPresentationAdapter.make(
            applicationUsage: .init(state: .empty, intervals: [], summaries: [], observedRangeDuration: 0),
            inputAggregates: [aggregate]
        )

        #expect(result.state == .populated)
        #expect(result.input == .init(
            keyCount: 19,
            clickCount: 6,
            scrollCount: 7
        ))
        #expect(result.applications.isEmpty)
    }

    @Test("Unsigned input arithmetic fails closed instead of wrapping")
    func rejectsOverflow() {
        #expect(throws: ApplicationInputDetailPresentationAdapter.AggregationError.unsignedOverflow) {
            try ApplicationInputDetailPresentationAdapter.checkedAdd(UInt64.max, 1)
        }
    }

    private func aggregate(
        _ startValue: String,
        inputs: [ApplicationInputTotals]
    ) throws -> InputAggregate {
        let start = ISO8601DateFormatter().date(from: startValue)!
        return try InputAggregate(
            period: try InputAggregatePeriod(
                start: start,
                end: start.addingTimeInterval(3_600),
                granularity: .hour,
                timeZoneIdentifier: "UTC"
            ),
            applicationTotals: inputs,
            collectorVersions: ["test-v1"],
            layoutVersions: ["physical-v1"]
        )
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
