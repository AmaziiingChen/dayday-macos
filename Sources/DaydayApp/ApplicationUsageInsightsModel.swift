import Combine
import DaydayCore
import DaydayStorage
import Foundation

/// Read-only application-duration projection. It derives non-overlapping
/// foreground intervals from durable, privacy-filtered H1 facts; it is neither
/// a productivity score nor an inferred Activity.
struct ApplicationUsagePresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        case empty
        case populated
        case failure
    }

    struct Interval: Identifiable, Equatable, Sendable {
        let id: String
        let applicationIdentifier: ApplicationIdentifier
        let displayLabel: String
        let startedAt: Date
        let endedAt: Date
        let isOngoing: Bool

        var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    }

    struct Summary: Identifiable, Equatable, Sendable {
        let applicationIdentifier: ApplicationIdentifier
        let displayLabel: String
        let duration: TimeInterval
        let intervalCount: Int

        var id: UUID { applicationIdentifier.rawValue }
    }

    let state: State
    let intervals: [Interval]
    let summaries: [Summary]
    /// The visible part of the requested range. This is an objective range,
    /// not a claim that the user was active throughout it.
    let observedRangeDuration: TimeInterval
    let applicationSwitchCount: Int
    /// Missing application-context projections, or a range beginning after
    /// the first recorded context, means foreground facts are incomplete.
    let hasIncompleteForegroundFacts: Bool
    private let trackedDurationValue: TimeInterval
    init(
        state: State,
        intervals: [Interval],
        summaries: [Summary],
        observedRangeDuration: TimeInterval = 0,
        applicationSwitchCount: Int = 0,
        hasIncompleteForegroundFacts: Bool = false,
        trackedDuration: TimeInterval? = nil
    ) {
        self.state = state
        self.intervals = intervals
        self.summaries = summaries
        self.observedRangeDuration = observedRangeDuration
        self.applicationSwitchCount = applicationSwitchCount
        self.hasIncompleteForegroundFacts = hasIncompleteForegroundFacts
        self.trackedDurationValue = trackedDuration
            ?? intervals.reduce(0) { $0 + $1.duration }
    }

    var trackedDuration: TimeInterval {
        trackedDurationValue
    }

    /// Time in the visible range without a continuous foreground-application
    /// fact. It must not be read as idle, away, or unproductive time.
    var noForegroundFactDuration: TimeInterval {
        max(0, observedRangeDuration - trackedDuration)
    }
}

/// Pure projection kept in the App presentation layer. It intentionally
/// consumes no titles, document hints, browser context, or input aggregates.
enum ApplicationUsagePresentationAdapter {
    static func make(
        events: [ObjectiveEvent],
        applicationContexts: [EventID: ApplicationContextRecord],
        range: Range<Date>,
        now: Date
    ) -> ApplicationUsagePresentation {
        struct OpenInterval {
            let event: ObjectiveEvent
            let context: ApplicationContextRecord
        }

        guard range.lowerBound < range.upperBound else {
            return .init(state: .empty, intervals: [], summaries: [])
        }

        let end = min(max(now, range.lowerBound), range.upperBound)
        let sorted = events
            .filter {
                range.contains($0.occurredAt)
                    && $0.source.collector == .applicationWindowContext
                    && $0.source.collectorVersion
                        == ApplicationContextObservationVersion.foregroundApplication
                    && ($0.kind == .applicationContextChanged || $0.kind == .systemBoundary)
            }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : $0.occurredAt < $1.occurredAt
            }
        var open: OpenInterval?
        var intervals: [ApplicationUsagePresentation.Interval] = []
        var switchCount = 0
        var hasIncompleteForegroundFacts = sorted.first.map { $0.occurredAt > range.lowerBound } ?? true

        func close(_ interval: OpenInterval, at closing: Date, isOngoing: Bool = false) {
            let started = max(interval.event.occurredAt, range.lowerBound)
            let ended = min(closing, range.upperBound)
            guard ended > started else { return }
            intervals.append(.init(
                id: interval.event.id.rawValue.uuidString,
                applicationIdentifier: interval.context.applicationIdentifier,
                displayLabel: interval.context.displayLabelSnapshot,
                startedAt: started,
                endedAt: ended,
                isOngoing: isOngoing
            ))
        }

        for event in sorted {
            if event.kind == .applicationContextChanged,
               event.securityDisposition == .allowed {
                if let open { close(open, at: event.occurredAt) }
                guard let context = applicationContexts[event.id] else {
                    open = nil
                    hasIncompleteForegroundFacts = true
                    continue
                }
                if let open, open.context.applicationIdentifier != context.applicationIdentifier {
                    switchCount += 1
                }
                open = .init(event: event, context: context)
            } else if event.kind == .systemBoundary, let active = open {
                // A lifecycle, control, suppression, or unknown event is a
                // hard boundary: do not invent foreground continuity across it.
                close(active, at: event.occurredAt)
                open = nil
            }
        }

        if let open { close(open, at: end, isOngoing: true) }

        var totals: [ApplicationIdentifier: (label: String, duration: TimeInterval, count: Int)] = [:]
        for interval in intervals {
            let previous = totals[interval.applicationIdentifier]
                ?? (interval.displayLabel, 0, 0)
            totals[interval.applicationIdentifier] = (
                previous.label,
                previous.duration + interval.duration,
                previous.count + 1
            )
        }
        var summaries: [ApplicationUsagePresentation.Summary] = []
        summaries.reserveCapacity(totals.count)
        for (identifier, total) in totals {
            summaries.append(.init(
                applicationIdentifier: identifier,
                displayLabel: total.label,
                duration: total.duration,
                intervalCount: total.count
            ))
        }
        summaries.sort(by: summaryOrder)

        return .init(
            state: intervals.isEmpty ? .empty : .populated,
            intervals: intervals,
            summaries: summaries,
            observedRangeDuration: end.timeIntervalSince(range.lowerBound),
            applicationSwitchCount: switchCount,
            hasIncompleteForegroundFacts: hasIncompleteForegroundFacts,
            trackedDuration: intervals.reduce(0) { $0 + $1.duration }
        )
    }

    /// Advances only the currently open foreground interval. The full event
    /// sequence is sorted and projected when durable facts refresh; the
    /// one-second display clock must not repeat that work on the main actor.
    static func advanceOngoingInterval(
        in presentation: ApplicationUsagePresentation,
        range: Range<Date>,
        now: Date
    ) -> ApplicationUsagePresentation {
        guard presentation.state != .failure,
              range.lowerBound < range.upperBound
        else { return presentation }

        let visibleEnd = min(max(now, range.lowerBound), range.upperBound)
        let observedRangeDuration = max(
            presentation.observedRangeDuration,
            visibleEnd.timeIntervalSince(range.lowerBound)
        )
        var intervals = presentation.intervals
        var summaries = presentation.summaries
        var trackedDuration = presentation.trackedDuration

        if let intervalIndex = intervals.lastIndex(where: \.isOngoing) {
            let interval = intervals[intervalIndex]
            let endedAt = max(interval.endedAt, visibleEnd)
            let delta = endedAt.timeIntervalSince(interval.endedAt)
            if delta > 0 {
                trackedDuration += delta
                intervals[intervalIndex] = .init(
                    id: interval.id,
                    applicationIdentifier: interval.applicationIdentifier,
                    displayLabel: interval.displayLabel,
                    startedAt: interval.startedAt,
                    endedAt: endedAt,
                    isOngoing: true
                )
                if let summaryIndex = summaries.firstIndex(where: {
                    $0.applicationIdentifier == interval.applicationIdentifier
                }) {
                    let summary = summaries[summaryIndex]
                    summaries[summaryIndex] = .init(
                        applicationIdentifier: summary.applicationIdentifier,
                        displayLabel: summary.displayLabel,
                        duration: summary.duration + delta,
                        intervalCount: summary.intervalCount
                    )
                    summaries.sort(by: summaryOrder)
                }
            }
        }

        return .init(
            state: presentation.state,
            intervals: intervals,
            summaries: summaries,
            observedRangeDuration: observedRangeDuration,
            applicationSwitchCount: presentation.applicationSwitchCount,
            hasIncompleteForegroundFacts: presentation.hasIncompleteForegroundFacts,
            trackedDuration: trackedDuration
        )
    }

    private static func summaryOrder(
        _ lhs: ApplicationUsagePresentation.Summary,
        _ rhs: ApplicationUsagePresentation.Summary
    ) -> Bool {
        lhs.duration == rhs.duration
            ? lhs.applicationIdentifier.rawValue.uuidString
                < rhs.applicationIdentifier.rawValue.uuidString
            : lhs.duration > rhs.duration
    }

}

@MainActor
final class ApplicationUsageInsightsModel: ObservableObject {
    /// Capture facts may reach durable storage shortly after their occurrence.
    /// Re-read only the mutable tail so incremental refreshes stay cheap while
    /// still admitting delayed application-context events.
    private static let incrementalRefreshOverlap: TimeInterval = 120

    @Published private(set) var presentation = ApplicationUsagePresentation(
        state: .loading, intervals: [], summaries: []
    )
    @Published private(set) var isLoading = false

    private var repository: SQLiteObjectiveEventRepository?
    private var refreshTask: Task<Void, Never>?
    private var visibleRange: Range<Date>?
    private var loadedRangeAt: Date?
    private var refreshGeneration = 0
    private var contextCacheRangeLowerBound: Date?
    private var contextCache: [EventID: ApplicationContextRecord] = [:]
    private var cachedEvents: [ObjectiveEvent] = []

    func configure(repository: SQLiteObjectiveEventRepository) {
        self.repository = repository
        refresh(days: 1)
    }

    func refresh(days: Int) {
        refresh(range: Self.range(days: days, endingAt: .now))
    }

    /// Reads only durable objective facts in an explicit half-open range.
    /// The repository owns validation and keeps ordering stable.
    func refresh(range: Range<Date>, bypassCache: Bool = false) {
        guard let repository else { return }
        let now = Date()
        if !bypassCache && PresentationRangeCachePolicy.canReuse(
            loadedRange: visibleRange,
            loadedAt: loadedRangeAt,
            requestedRange: range,
            now: now,
            maximumAge: 10
        ) {
            visibleRange = range
            isLoading = false
            refreshVisibleDuration(at: now)
            return
        }
        let hasCompatiblePresentation = PresentationRangeCachePolicy.isCompatible(
            loadedRange: visibleRange,
            requestedRange: range,
            maximumMovingUpperBoundDelta: 35
        ) && presentation.state != .failure
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        isLoading = !hasCompatiblePresentation
        let cachedContexts = contextCacheRangeLowerBound.map {
            abs($0.timeIntervalSince(range.lowerBound)) < 1
        } == true ? contextCache : [:]
        let canFetchIncrementally = visibleRange.map {
            abs($0.lowerBound.timeIntervalSince(range.lowerBound)) < 1
                && range.upperBound >= $0.upperBound
        } == true
        let incrementalLowerBound = max(
            range.lowerBound,
            (visibleRange?.upperBound ?? range.lowerBound)
                .addingTimeInterval(-Self.incrementalRefreshOverlap)
        )
        let fetchRange = canFetchIncrementally
            ? incrementalLowerBound..<range.upperBound
            : range
        let cachedEventsAtRequest = canFetchIncrementally
            ? cachedEvents.filter { $0.occurredAt < incrementalLowerBound }
            : []
        refreshTask = Task { [weak self] in
            defer {
                if self?.refreshGeneration == generation {
                    self?.isLoading = false
                    self?.refreshTask = nil
                }
            }
            do {
                let freshValues = try await repository.fetch(occurredIn: fetchRange)
                let values = cachedEventsAtRequest + freshValues
                let contexts = try await Self.fetchContexts(
                    for: values,
                    repository: repository,
                    cached: cachedContexts
                )
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                let nextPresentation = await Task.detached(priority: .utility) {
                    ApplicationUsagePresentationAdapter.make(
                        events: values,
                        applicationContexts: contexts,
                        range: range,
                        now: now
                    )
                }.value
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                self?.visibleRange = range
                self?.loadedRangeAt = Date()
                self?.contextCacheRangeLowerBound = range.lowerBound
                self?.contextCache = contexts
                self?.cachedEvents = values
                self?.presentation = nextPresentation
            } catch {
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                if !hasCompatiblePresentation {
                    self?.presentation = .init(state: .failure, intervals: [], summaries: [])
                }
            }
        }
    }

    /// Advances only the visible open interval. It performs no disk I/O and
    /// remains truthful until the next bounded fact refresh observes a switch.
    func refreshVisibleDuration() {
        refreshVisibleDuration(at: .now)
    }

    /// A new durable foreground switch or boundary arrived. Rebuild only the
    /// current visible range; historical range caching still applies normally.
    func refreshForForegroundFactChange() {
        guard let visibleRange else { return }
        refresh(range: visibleRange, bypassCache: true)
    }

    private func refreshVisibleDuration(at now: Date) {
        guard let visibleRange else { return }
        let next = ApplicationUsagePresentationAdapter.advanceOngoingInterval(
            in: presentation,
            range: visibleRange,
            now: now
        )
        if next != presentation {
            presentation = next
        }
    }

    private static func range(days: Int, endingAt now: Date) -> Range<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let todayStart = (try? WorkdayBoundary.standard.start(containing: now, calendar: calendar))
            ?? calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -max(0, days - 1), to: todayStart)
            ?? todayStart
        return start..<now.addingTimeInterval(1)
    }

    static func fetchContexts(
        for events: [ObjectiveEvent],
        repository: SQLiteObjectiveEventRepository,
        cached: [EventID: ApplicationContextRecord] = [:]
    ) async throws -> [EventID: ApplicationContextRecord] {
        var values: [EventID: ApplicationContextRecord] = cached
        let missingIDs = events.compactMap { event -> EventID? in
            guard event.kind == .applicationContextChanged,
                  event.securityDisposition == .allowed,
                  values[event.id] == nil
            else { return nil }
            return event.id
        }
        let fetched = try await repository.fetchApplicationContexts(for: missingIDs)
        for (eventID, context) in fetched {
            values[eventID] = context
        }
        return values
    }
}
