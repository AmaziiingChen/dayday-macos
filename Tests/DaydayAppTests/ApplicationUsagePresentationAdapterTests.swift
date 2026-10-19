@testable import DaydayApp
import DaydayCore
import Foundation
import Testing

struct ApplicationUsagePresentationAdapterTests {
    @Test("System foreground intervals are non-overlapping and close at actual boundaries")
    func intervalsCloseAtSwitchAndBoundary() throws {
        let first = try applicationEvent(at: "2026-08-01T08:00:00Z")
        let second = try applicationEvent(at: "2026-08-01T08:10:00Z")
        let ordinaryFact = try ObjectiveEvent(
            kind: .stableStateObservation,
            occurredAt: instant("2026-08-01T08:05:00Z"),
            timeZoneIdentifier: "UTC",
            source: try CollectorSource(
                collector: .applicationWindowContext,
                collectorVersion: "test-v1",
                payloadSchemaVersion: 1
            ),
            securityDisposition: .allowed
        )
        let boundary = try ObjectiveEvent(
            kind: .systemBoundary,
            occurredAt: instant("2026-08-01T08:20:00Z"),
            timeZoneIdentifier: "UTC",
            source: try CollectorSource(
                collector: .applicationWindowContext,
                collectorVersion: ApplicationContextObservationVersion.foregroundApplication,
                payloadSchemaVersion: 1
            ),
            securityDisposition: .allowed
        )
        let firstApp = ApplicationIdentifier(rawValue: UUID())
        let secondApp = ApplicationIdentifier(rawValue: UUID())
        let result = ApplicationUsagePresentationAdapter.make(
            events: [first, ordinaryFact, second, boundary],
            applicationContexts: [
                first.id: try ApplicationContextRecord(
                    eventID: first.id,
                    applicationIdentifier: firstApp,
                    displayLabelSnapshot: "编辑器",
                    windowTitleSnapshot: "不应参与时长展示"
                ),
                second.id: try ApplicationContextRecord(
                    eventID: second.id,
                    applicationIdentifier: secondApp,
                    displayLabelSnapshot: "浏览器"
                ),
            ],
            range: instant("2026-08-01T08:00:00Z")..<instant("2026-08-01T08:30:00Z"),
            now: instant("2026-08-01T08:30:00Z")
        )

        #expect(result.state == .populated)
        #expect(result.intervals.map(\.duration) == [600, 600])
        #expect(result.intervals.allSatisfy { !$0.isOngoing })
        #expect(result.trackedDuration == 1_200)
        #expect(result.observedRangeDuration == 1_800)
        #expect(result.noForegroundFactDuration == 600)
        #expect(result.applicationSwitchCount == 1)
        #expect(!result.hasIncompleteForegroundFacts)
        #expect(result.summaries.map(\.displayLabel).sorted() == ["浏览器", "编辑器"])
    }

    @Test("The latest admitted foreground application advances only to the present")
    func openIntervalUsesNowAndNotTheRangeEnd() throws {
        let event = try applicationEvent(at: "2026-08-01T08:00:00Z")
        let application = ApplicationIdentifier(rawValue: UUID())
        let result = ApplicationUsagePresentationAdapter.make(
            events: [event],
            applicationContexts: [
                event.id: try ApplicationContextRecord(
                    eventID: event.id,
                    applicationIdentifier: application,
                    displayLabelSnapshot: "终端"
                ),
            ],
            range: instant("2026-08-01T08:00:00Z")..<instant("2026-08-01T09:00:00Z"),
            now: instant("2026-08-01T08:05:00Z")
        )

        let interval = try #require(result.intervals.first)
        #expect(interval.duration == 300)
        #expect(interval.isOngoing)
    }

    @Test("The display clock advances an open interval without rebuilding event history")
    func displayClockAdvancesOnlyOpenInterval() throws {
        let event = try applicationEvent(at: "2026-08-01T08:00:00Z")
        let application = ApplicationIdentifier(rawValue: UUID())
        let range = instant("2026-08-01T08:00:00Z")..<instant("2026-08-01T09:00:00Z")
        let initial = ApplicationUsagePresentationAdapter.make(
            events: [event],
            applicationContexts: [
                event.id: try ApplicationContextRecord(
                    eventID: event.id,
                    applicationIdentifier: application,
                    displayLabelSnapshot: "终端"
                ),
            ],
            range: range,
            now: instant("2026-08-01T08:05:00Z")
        )

        let advanced = ApplicationUsagePresentationAdapter.advanceOngoingInterval(
            in: initial,
            range: range,
            now: instant("2026-08-01T08:06:00Z")
        )

        #expect(advanced.intervals.first?.duration == 360)
        #expect(advanced.summaries.first?.duration == 360)
        #expect(advanced.observedRangeDuration == 360)
    }

    @Test("Missing durable application projection remains explicitly incomplete")
    func missingContextIsPartialFactSet() throws {
        let event = try applicationEvent(at: "2026-08-01T08:10:00Z")
        let result = ApplicationUsagePresentationAdapter.make(
            events: [event],
            applicationContexts: [:],
            range: instant("2026-08-01T08:00:00Z")..<instant("2026-08-01T08:30:00Z"),
            now: instant("2026-08-01T08:30:00Z")
        )

        #expect(result.state == .empty)
        #expect(result.hasIncompleteForegroundFacts)
        #expect(result.noForegroundFactDuration == 1_800)
        #expect(result.applicationSwitchCount == 0)
    }

    @Test("Window-context updates and collector heartbeats cannot split a system foreground interval")
    func ignoresLegacyWindowUpdatesAndCollectorHeartbeats() throws {
        let foreground = try applicationEvent(at: "2026-08-01T08:00:00Z")
        let legacyWindowUpdate = try ObjectiveEvent(
            kind: .applicationContextChanged,
            occurredAt: instant("2026-08-01T08:10:00Z"),
            timeZoneIdentifier: "UTC",
            source: try CollectorSource(
                collector: .applicationWindowContext,
                collectorVersion: "window-context-v1",
                payloadSchemaVersion: 1
            ),
            securityDisposition: .allowed
        )
        let heartbeat = try ObjectiveEvent(
            kind: .collectorStateTransition,
            occurredAt: instant("2026-08-01T08:20:00Z"),
            timeZoneIdentifier: "UTC",
            source: try CollectorSource(
                collector: .applicationWindowContext,
                collectorVersion: "test-v1",
                payloadSchemaVersion: 1
            ),
            securityDisposition: .allowed
        )
        let application = ApplicationIdentifier(rawValue: UUID())
        let result = ApplicationUsagePresentationAdapter.make(
            events: [foreground, legacyWindowUpdate, heartbeat],
            applicationContexts: [
                foreground.id: try ApplicationContextRecord(
                    eventID: foreground.id,
                    applicationIdentifier: application,
                    displayLabelSnapshot: "终端"
                ),
            ],
            range: instant("2026-08-01T08:00:00Z")..<instant("2026-08-01T09:00:00Z"),
            now: instant("2026-08-01T08:30:00Z")
        )

        #expect(result.intervals.count == 1)
        #expect(result.intervals.first?.duration == 1_800)
        #expect(result.intervals.first?.isOngoing == true)
    }

    private func applicationEvent(at timestamp: String) throws -> ObjectiveEvent {
        try ObjectiveEvent(
            kind: .applicationContextChanged,
            occurredAt: instant(timestamp),
            timeZoneIdentifier: "UTC",
            source: try CollectorSource(
                collector: .applicationWindowContext,
                collectorVersion: ApplicationContextObservationVersion.foregroundApplication,
                payloadSchemaVersion: 1
            ),
            securityDisposition: .allowed
        )
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
