import DaydayCapture
import DaydayCore
import DaydayStorage
import Combine
import Foundation
import OSLog

/// Read-only presentation model for aggregate-only input facts. It has no API
/// for recording input and it never receives raw keyboard or pointer events.
@MainActor
final class InputInsightsModel: ObservableObject {
    /// The renderer deliberately trails the collector by a fraction of a second.
    /// This is fast enough for a counter to feel live, but long enough for one
    /// numeric transition to settle before the next coalesced snapshot arrives.
    private static let livePresentationInterval: Duration = .milliseconds(240)
    private static let logger = Logger(
        subsystem: "app.dayday.local",
        category: "InputInsights"
    )
    @Published private(set) var aggregates: [InputAggregate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var liveStatus: InputCollectionRuntimeStatus = .idle
    @Published private(set) var keyboardLiveEnabled = false
    @Published private(set) var pointerLiveEnabled = false
    @Published private(set) var keyboardCounts: [UInt16: UInt64] = [:]
    @Published private(set) var metricSummary = InputMetricSummary.empty
    @Published private(set) var pointerDisplays: [PointerHeatmapPresentation] = []
    @Published private(set) var pointerHistoryDays: [PointerHistoryDayDescriptor] = []
    @Published private(set) var selectedPointerDayPresentation: PointerDayHeatmapPresentation?
    @Published private(set) var isPointerHistoryLoading = false
    @Published private(set) var pointerHistoryLoadFailed = false
    @Published private(set) var pointerPresentationFailed = false

    private var repository: SQLiteInputAggregateRepository?
    private weak var runtime: InputCollectionRuntime?
    private var refreshTask: Task<Void, Never>?
    private var pointerDayTask: Task<Void, Never>?
    private var livePresentationTask: Task<Void, Never>?
    private var pointerPresentationTask: Task<Void, Never>?
    private var runtimeUpdatesTask: Task<Void, Never>?
    private var storedAggregates: [InputAggregate] = []
    private var liveAggregates: [InputAggregate] = []
    private var activeRefreshID: UUID?
    private var activePointerDayRequestID: UUID?
    private var livePresentationRevision: UInt64 = 0
    private var pointerSourceRevision: UInt64 = 0
    private var pointerPresentationRevision: UInt64?
    private var pointerSourceDisplays: [[DisplayInputAggregate]] = []
    private var pointerHistorySnapshotDay: Date?
    private var selectedPointerDayID: String?
    private var pointerDayCache = PointerDayPresentationCache(capacity: 32)
    private var loadedRange: Range<Date>?
    private var loadedRangeAt: Date?
    private var loadedMutableDayStart: Date?
    private var historicalProjectionCache = InputHistoricalProjectionCache(capacity: 4)
    private var activeRange = Date()..<Date().addingTimeInterval(86_400)
    private var livePresentationToken: UUID?
    private var livePresentationMode: InputInsightsLivePresentationMode = .aggregatesOnly
    private var workdayBoundary = WorkdayBoundary.standard

    func configure(
        repository: SQLiteInputAggregateRepository,
        runtime: InputCollectionRuntime,
        workdayBoundary: WorkdayBoundary = .standard
    ) {
        self.repository = repository
        self.runtime = runtime
        self.workdayBoundary = workdayBoundary
        runtimeUpdatesTask?.cancel()
        runtimeUpdatesTask = Task { [weak self, weak runtime] in
            guard let runtime else { return }
            for await snapshot in runtime.statusUpdates() {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
                guard let self, self.livePresentationToken != nil else { continue }
                // Capture already coalesces raw callbacks. Keep the display
                // cadence below the shared numeric motion duration so a busy
                // keyboard or pointer never continuously restarts the entire
                // SwiftUI presentation tree.
                try? await Task.sleep(for: Self.livePresentationInterval)
                guard !Task.isCancelled else { return }
                await self.refreshLive(range: self.activeRange)
            }
        }
        refresh(days: 1)
        prewarmHistoricalProjections(repository: repository)
    }

    func updateWorkdayBoundary(_ boundary: WorkdayBoundary) {
        guard workdayBoundary != boundary else { return }
        workdayBoundary = boundary
        loadedRange = nil
        loadedRangeAt = nil
        loadedMutableDayStart = nil
        historicalProjectionCache = InputHistoricalProjectionCache(capacity: 4)
        pointerDayCache = PointerDayPresentationCache(capacity: 32)
        pointerHistorySnapshotDay = nil
        pointerHistoryDays = []
        selectedPointerDayPresentation = nil
    }

    func refresh(days: Int) {
        refresh(range: Self.range(days: days, endingAt: .now, boundary: workdayBoundary))
    }

    func refresh(range: Range<Date>) {
        activeRange = range
        guard let repository else { return }
        let now = Date()
        if PresentationRangeCachePolicy.canReuse(
            loadedRange: loadedRange,
            loadedAt: loadedRangeAt,
            requestedRange: range,
            now: now,
            maximumAge: 300
        ) {
            isLoading = false
            loadFailed = false
            return
        }
        if let cached = historicalProjectionCache.value(
            compatibleWith: range,
            now: now,
            maximumAge: 300
        ) {
            refreshTask?.cancel()
            activeRefreshID = nil
            let snapshot = liveAggregates.isEmpty
                ? cached.snapshot
                : InputInsightsPresentationBuilder.makeAggregateSnapshot(
                    stored: cached.stored,
                    live: liveAggregates
                )
            publishCachedRangeSnapshot(
                snapshot,
                stored: cached.stored,
                range: range,
                mutableDayStart: cached.mutableDayStart
            )
            return
        }
        let requestID = UUID()
        activeRefreshID = requestID
        refreshTask?.cancel()
        isLoading = !PresentationRangeCachePolicy.isCompatible(
            loadedRange: loadedRange,
            requestedRange: range,
            maximumMovingUpperBoundDelta: 35
        )
        loadFailed = false
        let liveAtRequest = liveAggregates
        let mutableDayStart = Self.logicalDayStart(containing: now, boundary: workdayBoundary)
        let canRefreshMutableTail = loadedRange.map {
            abs($0.lowerBound.timeIntervalSince(range.lowerBound)) < 1
                && range.upperBound >= $0.upperBound
        } == true
        let refreshLowerBound: Date
        let preservedStored: [InputAggregate]
        if canRefreshMutableTail {
            refreshLowerBound = min(loadedMutableDayStart ?? mutableDayStart, mutableDayStart)
            preservedStored = storedAggregates.filter {
                $0.period.start < refreshLowerBound
            }
        } else {
            refreshLowerBound = range.lowerBound
            preservedStored = []
        }
        let refreshRange = refreshLowerBound..<range.upperBound
        refreshTask = Task { [weak self] in
            // Picker changes often arrive in a burst. Debounce before sending
            // a payload-decoding query to the serialized SQLite actor so only
            // the final selection does real work.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                async let finalized = repository.fetch(startingIn: refreshRange)
                async let checkpoints = repository.openCheckpoints()
                let refreshed = try await finalized + checkpoints.map(\.aggregate).filter {
                    $0.period.start >= refreshRange.lowerBound
                        && $0.period.start < refreshRange.upperBound
                }
                let all = preservedStored + refreshed
                guard !Task.isCancelled else { return }
                let snapshot = await Task.detached(priority: .userInitiated) {
                    InputInsightsPresentationBuilder.makeAggregateSnapshot(
                        stored: all, live: liveAtRequest
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.publishRangeSnapshot(
                    snapshot,
                    stored: all,
                    range: range,
                    mutableDayStart: mutableDayStart,
                    requestID: requestID
                )
            } catch {
                Self.logger.error(
                    "Unable to refresh input aggregates: \(String(describing: error), privacy: .public)"
                )
                self?.failRangeRefresh(requestID)
            }
        }
    }

    /// Builds a lightweight calendar index without touching SQLite payloads.
    /// An individual day is decoded only after selection, so entering the mouse
    /// tab can never fan out into 180 days of JSON work.
    func refreshPointerHistory() {
        let snapshotDay = Self.logicalDayStart(containing: .now, boundary: workdayBoundary)
        if pointerHistorySnapshotDay == snapshotDay { return }
        pointerHistoryDays = PointerHistoryDayIndex.make(
            dayCount: 180,
            endingAt: .now,
            boundary: workdayBoundary
        )
        pointerHistorySnapshotDay = snapshotDay
        pointerHistoryLoadFailed = false
        isPointerHistoryLoading = false
    }

    /// Reads at most one logical day and keeps completed-day projections in a
    /// bounded LRU cache. Today is always revalidated because its aggregate is
    /// still changing; older days are immutable presentation facts.
    func refreshPointerDay(startingAt logicalDayStart: Date?) {
        guard let logicalDayStart,
              let day = pointerHistoryDays.first(where: {
                  $0.logicalDayStart == logicalDayStart
              })
        else {
            selectedPointerDayID = nil
            selectedPointerDayPresentation = nil
            isPointerHistoryLoading = false
            return
        }
        selectedPointerDayID = day.id
        pointerDayTask?.cancel()
        activePointerDayRequestID = nil

        let currentDayStart = Self.logicalDayStart(containing: .now, boundary: workdayBoundary)
        let isCurrentDay = day.logicalDayStart == currentDayStart
        if !isCurrentDay, let cached = pointerDayCache.value(for: day.id) {
            selectedPointerDayPresentation = cached.presentation
            pointerHistoryLoadFailed = false
            isPointerHistoryLoading = false
            return
        }

        guard let repository else { return }
        let requestID = UUID()
        activePointerDayRequestID = requestID
        // The previous day may remain painted while the new day is decoded,
        // but the picker should still expose that fresh work is in flight.
        isPointerHistoryLoading = true
        pointerHistoryLoadFailed = false
        let liveAtRequest = liveAggregates.filter {
            $0.period.end > day.range.lowerBound && $0.period.start < day.range.upperBound
        }
        let boundary = workdayBoundary
        pointerDayTask = Task { [weak self] in
            defer { self?.finishPointerDayRequest(requestID) }
            do {
                let stored = try await repository.fetch(startingIn: day.range)
                guard !Task.isCancelled else { return }
                let snapshot = await Task.detached(priority: .utility) {
                    InputInsightsPresentationBuilder.makePointerHistorySnapshot(
                        stored: stored, live: liveAtRequest, boundary: boundary
                    )
                }.value
                guard !Task.isCancelled else { return }
                guard let self,
                      self.activePointerDayRequestID == requestID,
                      self.selectedPointerDayID == day.id
                else { return }
                let presentation = snapshot.days.first(where: {
                    $0.logicalDayStart == day.logicalDayStart
                })
                if !isCurrentDay, !snapshot.loadFailed {
                    self.pointerDayCache.insert(
                        PointerDayPresentationCache.Value(presentation: presentation),
                        for: day.id
                    )
                }
                self.selectedPointerDayPresentation = presentation
                self.pointerHistoryLoadFailed = snapshot.loadFailed
            } catch {
                Self.logger.error(
                    "Unable to refresh pointer day: \(String(describing: error), privacy: .public)"
                )
                guard self?.activePointerDayRequestID == requestID else { return }
                self?.pointerHistoryLoadFailed = true
            }
        }
    }

    func beginLivePresentation(
        range: Range<Date>,
        mode: InputInsightsLivePresentationMode = .aggregatesOnly
    ) -> UUID {
        let token = UUID()
        activeRange = range
        livePresentationToken = token
        livePresentationMode = mode
        if mode == .pointerOverview {
            schedulePointerPresentationBuild()
        }
        return token
    }

    func endLivePresentation(_ token: UUID) {
        guard livePresentationToken == token else { return }
        livePresentationToken = nil
        livePresentationMode = .aggregatesOnly
    }

    /// Samples the already-coarsened in-memory totals at the presentation
    /// cadence. It intentionally has no persistence side effect.
    func refreshLive(range: Range<Date>) async {
        guard let runtime else { return }
        activeRange = range
        apply(runtime.snapshot)
        do {
            let now = Date()
            let values = try await runtime.liveAggregates().filter {
                $0.period.end > range.lowerBound && $0.period.start <= now
            }
            guard values != liveAggregates else { return }
            liveAggregates = values
            refreshLivePresentation()
        } catch {
            liveStatus = .unavailable
        }
    }

    private static func range(
        days: Int,
        endingAt now: Date,
        boundary: WorkdayBoundary
    ) -> Range<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let todayStart = (try? boundary.start(containing: now, calendar: calendar))
            ?? calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -max(0, days - 1), to: todayStart)
            ?? todayStart
        return start..<now.addingTimeInterval(1)
    }

    private static func logicalDayStart(
        containing date: Date,
        boundary: WorkdayBoundary
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return (try? boundary.start(containing: date, calendar: calendar))
            ?? calendar.startOfDay(for: date)
    }

    private func apply(_ snapshot: InputCollectionRuntimeSnapshot) {
        if liveStatus != snapshot.status { liveStatus = snapshot.status }
        if keyboardLiveEnabled != snapshot.keyboardEnabled { keyboardLiveEnabled = snapshot.keyboardEnabled }
        if pointerLiveEnabled != snapshot.pointerEnabled { pointerLiveEnabled = snapshot.pointerEnabled }
    }

    private func publishRangeSnapshot(
        _ snapshot: InputAggregatePresentationSnapshot,
        stored: [InputAggregate],
        range: Range<Date>,
        mutableDayStart: Date,
        requestID: UUID
    ) {
        guard activeRefreshID == requestID else { return }
        livePresentationRevision &+= 1
        notePointerSourceChange(in: snapshot.aggregates)
        storedAggregates = stored
        aggregates = snapshot.aggregates
        keyboardCounts = snapshot.keyboardCounts
        metricSummary = snapshot.metricSummary
        loadedRange = range
        loadedRangeAt = Date()
        loadedMutableDayStart = mutableDayStart
        isLoading = false
        refreshTask = nil
        if livePresentationMode == .pointerOverview {
            schedulePointerPresentationBuild()
        }
        historicalProjectionCache.insert(
            .init(
                range: range,
                stored: stored,
                snapshot: snapshot,
                loadedAt: loadedRangeAt ?? Date(),
                mutableDayStart: mutableDayStart
            )
        )
    }

    private func publishCachedRangeSnapshot(
        _ snapshot: InputAggregatePresentationSnapshot,
        stored: [InputAggregate],
        range: Range<Date>,
        mutableDayStart: Date
    ) {
        livePresentationRevision &+= 1
        notePointerSourceChange(in: snapshot.aggregates)
        storedAggregates = stored
        aggregates = snapshot.aggregates
        keyboardCounts = snapshot.keyboardCounts
        metricSummary = snapshot.metricSummary
        loadedRange = range
        loadedRangeAt = Date()
        loadedMutableDayStart = mutableDayStart
        isLoading = false
        loadFailed = false
        if livePresentationMode == .pointerOverview {
            schedulePointerPresentationBuild()
        }
    }

    private func prewarmHistoricalProjections(repository: SQLiteInputAggregateRepository) {
        let boundary = workdayBoundary
        Task { [weak self, repository, boundary] in
            for dayCount in [7, 30] {
                guard !Task.isCancelled else { return }
                let now = Date()
                let range = Self.range(days: dayCount, endingAt: now, boundary: boundary)
                do {
                    let stored = try await repository.fetch(startingIn: range)
                    let snapshot = await Task.detached(priority: .utility) {
                        InputInsightsPresentationBuilder.makeAggregateSnapshot(
                            stored: stored,
                            live: []
                        )
                    }.value
                    guard let self, !Task.isCancelled else { return }
                    self.historicalProjectionCache.insert(
                        .init(
                            range: range,
                            stored: stored,
                            snapshot: snapshot,
                            loadedAt: Date(),
                            mutableDayStart: Self.logicalDayStart(
                                containing: now,
                                boundary: boundary
                            )
                        )
                    )
                    _ = snapshot
                } catch {
                    continue
                }
            }
        }
    }

    private func failRangeRefresh(_ requestID: UUID) {
        guard activeRefreshID == requestID else { return }
        isLoading = false
        loadFailed = true
        refreshTask = nil
    }

    private func finishPointerDayRequest(_ requestID: UUID) {
        guard activePointerDayRequestID == requestID else { return }
        isPointerHistoryLoading = false
        pointerDayTask = nil
    }

    /// Live input updates are frequent. Merge the current open bucket and its
    /// keyboard totals off the main actor, but do not build a 32×24 pointer
    /// grid unless the mouse presentation is actually visible.
    private func refreshLivePresentation() {
        livePresentationRevision &+= 1
        guard livePresentationTask == nil else { return }
        startLivePresentationBuild()
    }

    private func startLivePresentationBuild() {
        let revision = livePresentationRevision
        let stored = storedAggregates
        let live = liveAggregates
        livePresentationTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                InputInsightsPresentationBuilder.makeAggregateSnapshot(stored: stored, live: live)
            }.value
            guard let self else { return }
            let needsFollowUp = self.livePresentationRevision != revision
            if !Task.isCancelled {
                // A live aggregate changes continuously while the pointer is
                // moving. Previously every completed projection was discarded
                // whenever a newer input notification arrived, which meant a
                // sustained interaction could leave the visible counters
                // frozen until the person stopped. Publish this coherent
                // snapshot, then immediately coalesce one follow-up build.
                if self.aggregates != snapshot.aggregates {
                    self.notePointerSourceChange(in: snapshot.aggregates)
                    self.aggregates = snapshot.aggregates
                }
                if self.keyboardCounts != snapshot.keyboardCounts {
                    self.keyboardCounts = snapshot.keyboardCounts
                }
                if self.metricSummary != snapshot.metricSummary {
                    self.metricSummary = snapshot.metricSummary
                }
                if self.livePresentationMode == .pointerOverview {
                    self.schedulePointerPresentationBuild()
                }
            }
            self.livePresentationTask = nil
            if !Task.isCancelled, needsFollowUp {
                self.startLivePresentationBuild()
            }
        }
    }

    /// Keeps a completed pointer projection available across keyboard/mouse
    /// switches. If aggregates changed while the keyboard was visible, the
    /// previous grid paints immediately and one coalesced background rebuild
    /// replaces it when ready.
    private func schedulePointerPresentationBuild() {
        guard pointerPresentationRevision != pointerSourceRevision else { return }
        guard pointerPresentationTask == nil else { return }
        startPointerPresentationBuild()
    }

    private func startPointerPresentationBuild() {
        let revision = pointerSourceRevision
        let values = aggregates
        pointerPresentationTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                InputInsightsPresentationBuilder.makePointerSnapshot(from: values)
            }.value
            guard let self else { return }
            if !Task.isCancelled, self.pointerSourceRevision == revision {
                if self.pointerDisplays != snapshot.displays {
                    self.pointerDisplays = snapshot.displays
                }
                if self.pointerPresentationFailed != snapshot.loadFailed {
                    self.pointerPresentationFailed = snapshot.loadFailed
                }
                self.pointerPresentationRevision = revision
            }
            self.pointerPresentationTask = nil
            if !Task.isCancelled,
               self.livePresentationMode == .pointerOverview,
               self.pointerPresentationRevision != self.pointerSourceRevision {
                self.startPointerPresentationBuild()
            }
        }
    }

    /// Keyboard-only changes must not rebuild the 32×24 pointer projection.
    /// The nested display arrays share their storage with the aggregate
    /// snapshot, so equality is a cheap modality gate in the common case.
    private func notePointerSourceChange(in values: [InputAggregate]) {
        let displays = values.map(\.displays)
        guard displays != pointerSourceDisplays else { return }
        pointerSourceDisplays = displays
        pointerSourceRevision &+= 1
    }
}

/// Small process-local cache for already-decoded daily/hourly projections.
/// Long completed ranges are immutable because storage rolls old hour buckets
/// into daily aggregates; a range containing the moving workday expires after
/// the same short window as the active presentation cache.
struct InputHistoricalProjectionCache {
    struct Entry: Sendable {
        let range: Range<Date>
        let stored: [InputAggregate]
        let snapshot: InputAggregatePresentationSnapshot
        let loadedAt: Date
        let mutableDayStart: Date
    }

    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(
        compatibleWith requestedRange: Range<Date>,
        now: Date,
        maximumAge: TimeInterval
    ) -> Entry? {
        guard let index = entries.firstIndex(where: {
            PresentationRangeCachePolicy.canReuse(
                loadedRange: $0.range,
                loadedAt: $0.loadedAt,
                requestedRange: requestedRange,
                now: now,
                maximumAge: maximumAge
            )
        }) else { return nil }
        let value = entries.remove(at: index)
        entries.insert(value, at: 0)
        return value
    }

    mutating func insert(_ entry: Entry) {
        entries.removeAll {
            abs($0.range.lowerBound.timeIntervalSince(entry.range.lowerBound)) < 1
                && abs($0.range.upperBound.timeIntervalSince(entry.range.upperBound)) < 1
        }
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

enum InputInsightsLivePresentationMode: Sendable {
    case aggregatesOnly
    case pointerOverview
}

/// A semantic range cache makes switching between sibling insight tabs paint
/// the already-loaded range immediately. Closed historical ranges are
/// immutable; a moving "now" upper bound may drift only by the cache age.
enum PresentationRangeCachePolicy {
    static func canReuse(
        loadedRange: Range<Date>?,
        loadedAt: Date?,
        requestedRange: Range<Date>,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard let loadedAt else { return false }
        if requestedRange.upperBound <= now.addingTimeInterval(-60) {
            return isCompatible(
                loadedRange: loadedRange,
                requestedRange: requestedRange,
                maximumMovingUpperBoundDelta: 1
            )
        }
        let age = now.timeIntervalSince(loadedAt)
        guard age >= 0, age <= maximumAge else { return false }
        return isCompatible(
            loadedRange: loadedRange,
            requestedRange: requestedRange,
            maximumMovingUpperBoundDelta: maximumAge + 2
        )
    }

    static func isCompatible(
        loadedRange: Range<Date>?,
        requestedRange: Range<Date>,
        maximumMovingUpperBoundDelta: TimeInterval
    ) -> Bool {
        guard let loadedRange,
              requestedRange.lowerBound < requestedRange.upperBound,
              abs(loadedRange.lowerBound.timeIntervalSince(requestedRange.lowerBound)) < 1
        else { return false }
        return abs(loadedRange.upperBound.timeIntervalSince(requestedRange.upperBound))
            <= maximumMovingUpperBoundDelta
    }
}

/// Read-only, range-wide mouse totals for the heatmap. This combines only
/// already-coarsened hourly buckets, never event points or event order.
struct PointerHeatmapPresentation: Identifiable, Equatable, Sendable {
    let display: DisplayInputAggregate

    var id: DisplayContext { display.display }
}

/// A single logical day's normalized mouse totals. This keeps past days
/// browseable without exposing coordinates, timestamps, or a replayable path.
struct PointerDayHeatmapPresentation: Identifiable, Equatable, Sendable {
    let logicalDayStart: Date
    let timeZoneIdentifier: String
    let display: DisplayInputAggregate
    let detectedInteractionMilliseconds: UInt64

    var id: String { "\(timeZoneIdentifier)|\(logicalDayStart.timeIntervalSinceReferenceDate)" }
}

/// Lightweight calendar identity used by the picker. It contains no decoded
/// aggregate payload, so generating 180 entries is cheap and deterministic.
struct PointerHistoryDayDescriptor: Identifiable, Equatable, Hashable, Sendable {
    let logicalDayStart: Date
    let timeZoneIdentifier: String
    let range: Range<Date>
    let displayTitle: String

    var id: String { "\(timeZoneIdentifier)|\(logicalDayStart.timeIntervalSinceReferenceDate)" }
}

enum PointerHistoryDayIndex {
    static func make(
        dayCount: Int,
        endingAt now: Date,
        calendar suppliedCalendar: Calendar = .autoupdatingCurrent,
        boundary: WorkdayBoundary = .standard
    ) -> [PointerHistoryDayDescriptor] {
        guard dayCount > 0 else { return [] }
        var calendar = suppliedCalendar
        let timeZone = calendar.timeZone
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard var start = try? boundary.start(containing: now, calendar: calendar) else {
            return []
        }
        var days: [PointerHistoryDayDescriptor] = []
        days.reserveCapacity(dayCount)
        for _ in 0..<dayCount {
            guard let nextCandidate = calendar.date(byAdding: .day, value: 1, to: start),
                  let end = try? boundary.start(containing: nextCandidate, calendar: calendar),
                  end > start
            else { break }
            days.append(.init(
                logicalDayStart: start,
                timeZoneIdentifier: timeZone.identifier,
                range: start..<end,
                displayTitle: formatter.string(from: start)
            ))
            guard let previousCandidate = calendar.date(byAdding: .day, value: -1, to: start),
                  let previous = try? boundary.start(
                    containing: previousCandidate,
                    calendar: calendar
                  ),
                  previous < start
            else { break }
            start = previous
        }
        return days
    }
}

/// Process-local and intentionally bounded. Completed days are immutable, but
/// retaining every decoded 32×24 grid would work against the lightweight-app
/// budget, so only the 32 most recently inspected days stay resident.
struct PointerDayPresentationCache {
    struct Value: Sendable {
        let presentation: PointerDayHeatmapPresentation?
    }

    private let capacity: Int
    private var values: [String: Value] = [:]
    private var recency: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        recency.removeAll(where: { $0 == key })
        recency.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String) {
        values[key] = value
        recency.removeAll(where: { $0 == key })
        recency.append(key)
        while recency.count > capacity {
            let evicted = recency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }
}

struct InputAggregatePresentationSnapshot: Sendable {
    let aggregates: [InputAggregate]
    let keyboardCounts: [UInt16: UInt64]
    let metricSummary: InputMetricSummary
}

struct InputRangePresentationSnapshot: Sendable {
    let aggregates: [InputAggregate]
    let pointerDisplays: [PointerHeatmapPresentation]
    let pointerPresentationFailed: Bool
}

struct PointerHistoryPresentationSnapshot: Sendable {
    let days: [PointerDayHeatmapPresentation]
    let loadFailed: Bool
}

struct PointerPresentationSnapshot: Sendable {
    let displays: [PointerHeatmapPresentation]
    let loadFailed: Bool
}

enum InputInsightsPresentationBuilder {
    static func makeAggregateSnapshot(
        stored: [InputAggregate],
        live: [InputAggregate]
    ) -> InputAggregatePresentationSnapshot {
        let aggregates = uniquePeriods(stored + live)
        return InputAggregatePresentationSnapshot(
            aggregates: aggregates,
            keyboardCounts: makeKeyboardCounts(from: aggregates),
            metricSummary: InputMetricSummary.make(from: aggregates)
        )
    }

    static func makeRangeSnapshot(
        stored: [InputAggregate],
        live: [InputAggregate]
    ) -> InputRangePresentationSnapshot {
        let aggregates = uniquePeriods(stored + live)
        do {
            return InputRangePresentationSnapshot(
                aggregates: aggregates,
                pointerDisplays: try PointerHeatmapPresentationAdapter.make(from: aggregates),
                pointerPresentationFailed: false
            )
        } catch {
            return InputRangePresentationSnapshot(
                aggregates: aggregates,
                pointerDisplays: [],
                pointerPresentationFailed: true
            )
        }
    }

    static func makePointerSnapshot(from aggregates: [InputAggregate]) -> PointerPresentationSnapshot {
        do {
            return PointerPresentationSnapshot(
                displays: try PointerHeatmapPresentationAdapter.make(from: aggregates),
                loadFailed: false
            )
        } catch {
            return PointerPresentationSnapshot(displays: [], loadFailed: true)
        }
    }

    static func makePointerHistorySnapshot(
        stored: [InputAggregate],
        live: [InputAggregate],
        boundary: WorkdayBoundary = .standard
    ) -> PointerHistoryPresentationSnapshot {
        do {
            return PointerHistoryPresentationSnapshot(
                days: try PointerHeatmapPresentationAdapter.makePerDay(
                    from: uniquePeriods(stored + live),
                    boundary: boundary
                ),
                loadFailed: false
            )
        } catch {
            return PointerHistoryPresentationSnapshot(days: [], loadFailed: true)
        }
    }

    private static func makeKeyboardCounts(from aggregates: [InputAggregate]) -> [UInt16: UInt64] {
        aggregates.reduce(into: [:]) { result, aggregate in
            for key in aggregate.physicalKeyCounts {
                let sum = result[key.hardwareKeyCode, default: 0]
                    .addingReportingOverflow(key.count)
                result[key.hardwareKeyCode] = sum.overflow ? UInt64.max : sum.partialValue
            }
        }
    }

    private static func uniquePeriods(_ values: [InputAggregate]) -> [InputAggregate] {
        var byPeriod: [InputAggregatePeriod: InputAggregate] = [:]
        for value in values {
            if let existing = byPeriod[value.period], existing.id != value.id { continue }
            byPeriod[value.period] = value
        }
        return byPeriod.values.sorted { $0.period.start < $1.period.start }
    }
}

enum PointerHeatmapPresentationAdapter {
    enum AggregationError: Error {
        case incompatibleGrid
        case unsignedOverflow
    }

    private struct CellKey: Hashable {
        let row: UInt16
        let column: UInt16
    }

    /// One merged grid across the whole requested range. Display identity is
    /// deliberately opaque and only stable within a capture reconciliation,
    /// so long ranges are intentionally coarse.
    static func make(from aggregates: [InputAggregate]) throws -> [PointerHeatmapPresentation] {
        // DisplayContext IDs are deliberately opaque and only stable for the
        // lifetime of capture reconciliation. They must not be presented as a
        // physical-monitor list after an app restart. Every display grid has
        // already been normalized, so a single range-wide heatmap is the
        // truthful, readable view of the persisted facts.
        let displayTotals = aggregates
            .sorted(by: { $0.period.start < $1.period.start })
            .flatMap(\.displays)

        guard let combined = try combine(displayTotals) else { return [] }
        return [PointerHeatmapPresentation(display: combined)]
    }

    /// Groups retained hourly or daily pointer facts into per-logical-day grids so a user can
    /// browse history by day rather than only a flat range-wide heatmap.
    static func makePerDay(
        from aggregates: [InputAggregate],
        boundary: WorkdayBoundary = .standard
    ) throws -> [PointerDayHeatmapPresentation] {
        let orderedAggregates = aggregates.sorted(by: { $0.period.start < $1.period.start })

        struct DayKey: Hashable {
            let start: Date
            let timeZoneIdentifier: String
        }

        var displaysByDay: [DayKey: [DisplayInputAggregate]] = [:]
        var durationByDay: [DayKey: UInt64] = [:]

        for aggregate in orderedAggregates {
            guard let timeZone = TimeZone(identifier: aggregate.period.timeZoneIdentifier) else {
                continue
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let logicalDayStart = try boundary.start(
                containing: aggregate.period.start, calendar: calendar
            )
            let key = DayKey(
                start: logicalDayStart,
                timeZoneIdentifier: aggregate.period.timeZoneIdentifier
            )
            displaysByDay[key, default: []].append(contentsOf: aggregate.displays)
            durationByDay[key, default: 0] = try add(
                durationByDay[key, default: 0],
                aggregate.includedDurationMilliseconds
            )
        }

        return try displaysByDay.compactMap { key, displays -> PointerDayHeatmapPresentation? in
            guard let combined = try combine(displays) else { return nil }
            return PointerDayHeatmapPresentation(
                logicalDayStart: key.start,
                timeZoneIdentifier: key.timeZoneIdentifier,
                display: combined,
                detectedInteractionMilliseconds: durationByDay[key, default: 0]
            )
        }
        .sorted { $0.logicalDayStart > $1.logicalDayStart }
    }

    /// Combines an arbitrary number of normalized displays with one cell map
    /// and one final grid construction. Rebuilding and sorting the grid after
    /// every hourly aggregate made long-range mouse views allocation-heavy.
    private static func combine(
        _ displays: [DisplayInputAggregate]
    ) throws -> DisplayInputAggregate? {
        guard let first = displays.first else { return nil }

        var pointer = first.pointer
        var cells = Dictionary(uniqueKeysWithValues: first.grid.cells.map {
            (CellKey(row: $0.row, column: $0.column), $0)
        })
        for display in displays.dropFirst() {
            guard
                first.grid.rows == display.grid.rows,
                first.grid.columns == display.grid.columns
            else {
                throw AggregationError.incompatibleGrid
            }

            pointer = try merge(pointer, display.pointer)
            for cell in display.grid.cells {
                let key = CellKey(row: cell.row, column: cell.column)
                if let existing = cells[key] {
                    cells[key] = NormalizedGridCell(
                        row: key.row,
                        column: key.column,
                        clicks: try merge(existing.clicks, cell.clicks),
                        dwellMilliseconds: try add(
                            existing.dwellMilliseconds,
                            cell.dwellMilliseconds
                        )
                    )
                } else {
                    cells[key] = cell
                }
            }
        }

        return DisplayInputAggregate(
            display: first.display,
            pointer: pointer,
            grid: try NormalizedDisplayGrid(
                rows: first.grid.rows,
                columns: first.grid.columns,
                cells: Array(cells.values)
            )
        )
    }

    private static func merge(_ lhs: PointerTotals, _ rhs: PointerTotals) throws -> PointerTotals {
        PointerTotals(
            clicks: try merge(lhs.clicks, rhs.clicks),
            scroll: ScrollTotals(
                up: try add(lhs.scroll.up, rhs.scroll.up),
                down: try add(lhs.scroll.down, rhs.scroll.down),
                left: try add(lhs.scroll.left, rhs.scroll.left),
                right: try add(lhs.scroll.right, rhs.scroll.right)
            ),
            scrollEventCount: try add(lhs.scrollEventCount, rhs.scrollEventCount),
            estimatedDistanceMilliPoints: try add(
                lhs.estimatedDistanceMilliPoints,
                rhs.estimatedDistanceMilliPoints
            )
        )
    }

    private static func merge(_ lhs: ClickCounts, _ rhs: ClickCounts) throws -> ClickCounts {
        ClickCounts(
            left: try add(lhs.left, rhs.left),
            right: try add(lhs.right, rhs.right),
            other: try add(lhs.other, rhs.other)
        )
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw AggregationError.unsignedOverflow }
        return result.partialValue
    }
}
