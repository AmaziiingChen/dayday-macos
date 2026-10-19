import DaydayCore
import Foundation

/// App-owned persistence + autosave for the user's journal.
///
/// Journal text is deliberately treated as exact user-authored content: autosave updates one
/// current original without rewriting, normalizing, or manufacturing a revision history.
/// Nothing here feeds the work-report allowlist.
@MainActor
final class JournalEntryModel: ObservableObject {
  /// The editor owns the hot typing path. Its snapshots update this exact draft without publishing
  /// the entire journal view on every autosave checkpoint; only externally initiated replacements
  /// (restore, attachment removal) increment `editorContentRevision` and flow back into WebKit.
  private(set) var body = ""
  @Published private(set) var hasContent = false
  @Published private(set) var editorContentRevision = 0
  @Published private(set) var selectedDay: DayDescriptor?
  @Published private(set) var pendingSelectedDay: DayDescriptor?
  @Published private(set) var isSwitchingDay = false
  private(set) var currentOriginalVersionNumber = 0
  private(set) var savedAt: Date?
  @Published private(set) var status = "日记尚未连接本地存储"
  @Published private(set) var isReady = false

  private var repository: (any JournalEntryRepository)?
  private var pendingAutosave: Task<Void, Never>?
  private var persistenceTask: Task<Void, Never>?
  private var hasUnsavedChanges = false
  private var currentEntryID: JournalEntryID?
  private var currentEntryDayID: DayID?
  private var selectionGeneration = 0
  private var persistedRecordHandler: (@MainActor (PersistedJournalEntryRecord) -> Void)?
  private let saveDelay: Duration

  init(saveDelay: Duration = .milliseconds(700)) {
    self.saveDelay = saveDelay
  }

  func configure(repository: any JournalEntryRepository) {
    self.repository = repository
    isReady = true
    updateStatus("可以开始书写今天的日记")
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, selectionGeneration == 0 else { return }
      await restore(now: .now)
    }
  }

  func setPersistedRecordHandler(
    _ handler: (@MainActor (PersistedJournalEntryRecord) -> Void)?
  ) {
    persistedRecordHandler = handler
  }

  deinit {
    pendingAutosave?.cancel()
    persistenceTask?.cancel()
  }

  /// Reloads the current logical day's entry from disk. This is called after
  /// bootstrap and is the sole source that replaces editor content.
  func restore(now: Date = .now) async {
    do {
      let day = try Self.currentDay(at: now)
      await switchToDay(day, flushCurrentDay: selectedDay != nil)
    } catch {
      updateStatus("读取本机日记失败")
    }
  }

  /// Selects a civil calendar date for reading and editing. The current draft is flushed before
  /// the new day is loaded, and autosave remains bound to the selected logical day afterwards.
  func selectCalendarDay(_ date: Date) async {
    do {
      let day = try Self.dayDescriptor(forCivilDate: date)
      await switchToDay(day, flushCurrentDay: true)
    } catch {
      updateStatus("无法打开这一天的日记")
    }
  }

  func selectDay(_ day: DayDescriptor) async {
    await switchToDay(day, flushCurrentDay: true)
  }

  var isSelectedDayToday: Bool {
    guard let selectedDay, let today = try? Self.currentDay(at: .now) else { return true }
    return selectedDay.id == today.id
  }

  /// The calendar can acknowledge a click immediately while the editor safely flushes the
  /// previous draft and loads the requested day in the background.
  var presentedDay: DayDescriptor? { pendingSelectedDay ?? selectedDay }

  /// Accepts a debounced snapshot from MarkEdit without invalidating the SwiftUI hierarchy around
  /// its WKWebView. This is the normal typing path and still schedules exact local persistence.
  func acceptEditorSnapshot(_ source: String) {
    guard source != body else { return }
    body = source
    hasUnsavedChanges = true
    updateHasContent(for: source)
    scheduleAutosave()
  }

  func flushPendingAutosave(now: Date = .now) async {
    pendingAutosave?.cancel()
    pendingAutosave = nil
    if hasUnsavedChanges {
      enqueueAutosave(now: now)
    }
    await persistenceTask?.value
  }

  /// Flushes the editor snapshot first, then returns the exact persisted source used by AI.
  func persistedRecordForDerivedOperation(now: Date = .now) async throws
    -> PersistedJournalEntryRecord
  {
    await flushPendingAutosave(now: now)
    guard let repository, let day = selectedDay,
      let record = try await repository.entry(for: day.id)
    else { throw JournalEntryAIError.missingPersistedOriginal }
    return record
  }

  /// Read-only lookup for sidebars and version menus. Unlike an explicit AI operation this never
  /// manufactures a save checkpoint or changes `updatedAt`.
  func persistedRecordForSelectedDay() async throws -> PersistedJournalEntryRecord {
    guard let repository, let day = selectedDay,
      let record = try await repository.entry(for: day.id)
    else { throw JournalEntryAIError.missingPersistedOriginal }
    return record
  }

  /// Explicit user acceptance is the only route from a derived copy back into the original.
  func acceptDerivedBody(_ source: String) {
    replaceEditorBody(source, schedulesAutosave: true)
    updateStatus("已采纳 AI 版本，正在自动保存")
  }

  private func scheduleAutosave() {
    guard hasUnsavedChanges else { return }
    pendingAutosave?.cancel()
    let delay = saveDelay
    pendingAutosave = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.enqueueAutosave(now: .now)
    }
  }

  private func enqueueAutosave(now: Date) {
    pendingAutosave = nil
    guard hasUnsavedChanges else { return }
    guard repository != nil else {
      updateStatus("本地存储尚未就绪，暂未保存")
      return
    }
    let body = body
    let day: DayDescriptor
    do {
      day = try selectedDay ?? Self.currentDay(at: now)
    } catch {
      updateStatus("无法确认日记日期，暂未保存")
      return
    }
    hasUnsavedChanges = false
    let precedingTask = persistenceTask
    persistenceTask = Task { @MainActor [weak self] in
      await precedingTask?.value
      guard !Task.isCancelled else { return }
      await self?.performAutosave(body: body, day: day, savedAt: now)
    }
  }

  private func performAutosave(
    body: String,
    day: DayDescriptor,
    savedAt now: Date
  ) async {
    guard let repository else { return }
    do {
      let existing = try await repository.entry(for: day.id)
      // A brand-new empty canvas is not a diary entry.  An existing entry, however,
      // must accept an empty body so that deleting every character cannot resurrect
      // yesterday's autosaved text after a relaunch.
      if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, existing == nil {
        updateStatus("还没有需要保存的日记")
        return
      }
      let entryID =
        existing?.entry.id
        ?? (currentEntryDayID == day.id ? currentEntryID : nil)
        ?? JournalEntryID()
      let original = try JournalOriginalVersion(
        id: existing?.currentOriginal.id ?? JournalOriginalVersionID(),
        journalEntryID: entryID,
        versionNumber: existing?.currentOriginal.versionNumber ?? 1,
        previousVersionID: existing?.currentOriginal.previousVersionID,
        body: body,
        savedAt: now
      )
      let entry: JournalEntry
      if let existing {
        entry = try existing.entry.replacingCurrentOriginal(original)
      } else {
        entry = try JournalEntry(
          id: entryID,
          dayID: day.id,
          initialOriginal: original,
          createdAt: now
        )
      }
      let record = try PersistedJournalEntryRecord(
        day: day,
        entry: entry,
        currentOriginal: original
      )
      let savedEmptyBody = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let saveResult = try await repository.save(record)
      persistedRecordHandler?(record)
      guard selectedDay?.id == day.id || selectedDay == nil else { return }
      switch saveResult {
      case .inserted, .updated:
        currentEntryID = entry.id
        currentEntryDayID = entry.dayID
        currentOriginalVersionNumber = entry.currentOriginalVersionNumber
        savedAt = entry.updatedAt
        updateStatus(
          savedEmptyBody ? "日记内容已清空并保存在本机" : "已自动保存到本机"
        )
      case .alreadyPresent:
        currentOriginalVersionNumber = entry.currentOriginalVersionNumber
        savedAt = entry.updatedAt
        updateStatus(
          savedEmptyBody ? "日记内容已清空并保存在本机" : "已保存到本机"
        )
      }
    } catch {
      if selectedDay?.id == day.id, self.body == body {
        hasUnsavedChanges = true
      }
      updateStatus("自动保存失败；你写的内容仍保留在编辑区内")
    }
  }

  /// Returns a stable private-entry anchor for an attachment or one-shot
  /// location captured before the first textual autosave. The next autosave
  /// adopts the same identifier, so private side artifacts cannot drift to an
  /// unrelated journal entry.
  func attachmentAnchor(now: Date = .now) async throws -> (entryID: JournalEntryID, dayID: DayID) {
    let day = try selectedDay ?? Self.currentDay(at: now)
    if let currentEntryID, currentEntryDayID == day.id {
      return (currentEntryID, day.id)
    }
    if let repository, let record = try await repository.entry(for: day.id) {
      currentEntryID = record.entry.id
      currentEntryDayID = record.entry.dayID
      return (record.entry.id, day.id)
    }
    let entryID = JournalEntryID()
    currentEntryID = entryID
    currentEntryDayID = day.id
    return (entryID, day.id)
  }

  @discardableResult
  func insertMarkdown(_ markdown: String, at selectedRange: NSRange) -> NSRange {
    let source = body as NSString
    let location = min(max(0, selectedRange.location), source.length)
    let length = min(max(0, selectedRange.length), source.length - location)
    let replacementRange = NSRange(location: location, length: length)
    replaceEditorBody(
      source.replacingCharacters(in: replacementRange, with: markdown),
      schedulesAutosave: true
    )
    return NSRange(location: location + (markdown as NSString).length, length: 0)
  }

  @discardableResult
  func insertImageReference(
    attachmentID: JournalAttachmentID,
    altText: String,
    at selectedRange: NSRange
  ) -> NSRange {
    let sanitized =
      altText
      .replacing("\\", with: "\\\\")
      .replacing("]", with: "\\]")
    let identifier = attachmentID.rawValue.uuidString.lowercased()
    let reference = "![\(sanitized)](dayday-attachment://\(identifier))"
    return insertMarkdown(reference, at: selectedRange)
  }

  func removeImageReference(_ attachmentID: JournalAttachmentID) {
    let identifier = NSRegularExpression.escapedPattern(
      for: attachmentID.rawValue.uuidString.lowercased()
    )
    guard
      let expression = try? NSRegularExpression(
        pattern: #"!?\[[^\]]*\]\(dayday-attachment://"# + identifier + #"\)"#
      )
    else { return }
    let range = NSRange(location: 0, length: (body as NSString).length)
    replaceEditorBody(
      expression.stringByReplacingMatches(in: body, range: range, withTemplate: ""),
      schedulesAutosave: true
    )
  }

  private func replaceEditorBody(_ source: String, schedulesAutosave: Bool) {
    guard source != body else {
      if !schedulesAutosave { hasUnsavedChanges = false }
      return
    }
    body = source
    hasUnsavedChanges = schedulesAutosave
    updateHasContent(for: source)
    editorContentRevision &+= 1
    if schedulesAutosave {
      scheduleAutosave()
    }
  }

  private func updateHasContent(for source: String) {
    let nextValue = !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasContent != nextValue {
      hasContent = nextValue
    }
  }

  private func updateStatus(_ nextStatus: String) {
    guard status != nextStatus else { return }
    status = nextStatus
  }

  private func switchToDay(_ day: DayDescriptor, flushCurrentDay: Bool) async {
    guard let repository else {
      updateStatus("本地存储尚未就绪，无法切换日期")
      return
    }
    if selectedDay?.id == day.id {
      if pendingSelectedDay != nil {
        selectionGeneration &+= 1
        pendingSelectedDay = nil
        isSwitchingDay = false
      }
      return
    }

    selectionGeneration &+= 1
    let generation = selectionGeneration
    pendingSelectedDay = day
    isSwitchingDay = true
    defer {
      if generation == selectionGeneration {
        pendingSelectedDay = nil
        isSwitchingDay = false
      }
    }
    if flushCurrentDay, selectedDay != nil {
      await flushPendingAutosave()
    }
    guard generation == selectionGeneration else { return }

    pendingAutosave?.cancel()
    pendingAutosave = nil
    do {
      let record = try await repository.entry(for: day.id)
      guard generation == selectionGeneration else { return }
      selectedDay = day
      currentEntryID = record?.entry.id
      currentEntryDayID = record?.entry.dayID
      currentOriginalVersionNumber = record?.entry.currentOriginalVersionNumber ?? 0
      savedAt = record?.entry.updatedAt
      replaceEditorBody(record?.currentOriginal.body ?? "", schedulesAutosave: false)
      if record != nil {
        updateStatus(
          isSelectedDayToday
            ? "已恢复今天的日记，保存在本机"
            : "已恢复这一天的日记，修改会自动保存到本机"
        )
      } else {
        updateStatus(
          isSelectedDayToday
            ? "今天还没有日记；写下第一句话就会自动保存"
            : "这一天还没有日记；开始书写后会自动保存"
        )
      }
    } catch {
      guard generation == selectionGeneration else { return }
      updateStatus("读取这一天的本机日记失败")
    }
  }

  private static func currentDay(at date: Date) throws -> DayDescriptor {
    let timeZone = TimeZone.autoupdatingCurrent
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = try WorkdayBoundary.standard.start(containing: date, calendar: calendar)
    guard let followingCivilDay = calendar.date(byAdding: .day, value: 1, to: start) else {
      throw JournalEntryDayError.nextDayUnavailable
    }
    let end = try WorkdayBoundary.standard.start(containing: followingCivilDay, calendar: calendar)
    let components = calendar.dateComponents([.year, .month, .day], from: start)
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw JournalEntryDayError.invalidDate
    }
    let logicalDate = try LogicalDayDate(year: year, month: month, day: day)
    return try DayDescriptor(
      id: stableDayID(
        logicalDate: logicalDate,
        timeZoneIdentifier: timeZone.identifier,
        boundaryHour: WorkdayBoundary.standard.hour
      ),
      logicalDate: logicalDate,
      timeZoneIdentifier: timeZone.identifier,
      boundary: .init(hour: WorkdayBoundary.standard.hour, startsAt: start, endsAt: end)
    )
  }

  private static func dayDescriptor(forCivilDate date: Date) throws -> DayDescriptor {
    let timeZone = TimeZone.autoupdatingCurrent
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard
      let year = components.year,
      let month = components.month,
      let day = components.day,
      let midday = calendar.date(
        from: DateComponents(
          timeZone: timeZone,
          year: year,
          month: month,
          day: day,
          hour: 12
        ))
    else { throw JournalEntryDayError.invalidDate }
    return try currentDay(at: midday)
  }

  private static func stableDayID(
    logicalDate: LogicalDayDate,
    timeZoneIdentifier: String,
    boundaryHour: Int
  ) -> DayID {
    let bytes = Array(
      "dayday|\(logicalDate.year)-\(logicalDate.month)-\(logicalDate.day)|\(timeZoneIdentifier)|\(boundaryHour)"
        .utf8
    )
    func hash(seed: UInt64) -> UInt64 {
      bytes.reduce(seed) { partial, byte in
        (partial ^ UInt64(byte)) &* 1_099_511_628_211
      }
    }
    let first = hash(seed: 14_695_981_039_346_656_037)
    let second = hash(seed: 7_809_847_782_465_536_322)
    var raw =
      withUnsafeBytes(of: first.bigEndian, Array.init)
      + withUnsafeBytes(of: second.bigEndian, Array.init)
    raw[6] = (raw[6] & 0x0F) | 0x80
    raw[8] = (raw[8] & 0x3F) | 0x80
    return DayID(
      rawValue: UUID(
        uuid: (
          raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
          raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        )))
  }
}

private enum JournalEntryDayError: Error {
  case nextDayUnavailable
  case invalidDate
}

enum JournalEntryAIError: Error {
  case missingPersistedOriginal
}

@MainActor
final class JournalHistoryModel: ObservableObject {
  @Published private(set) var entries: [PersistedJournalEntryRecord] = []
  @Published var searchText = ""
  @Published private(set) var status = "日记历史尚未连接本地存储"
  @Published private(set) var calendarCharacterCounts: [JournalLogicalDayKey: Int] = [:]
  @Published private(set) var statistics = JournalWritingStatistics(entries: [])
  @Published private(set) var heatmapPresentation = JournalWritingHeatmapPresentation(
    entries: [],
    endingAt: .now
  )

  private var repository: (any JournalEntryRepository)?
  private var hasLoaded = false
  private var visibleTextByEntryID: [JournalEntryID: String] = [:]

  var filteredEntries: [PersistedJournalEntryRecord] {
    let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return entries }
    return entries.filter {
      visibleTextByEntryID[$0.entry.id]?.localizedCaseInsensitiveContains(needle) == true
    }
  }

  func previewText(for entryID: JournalEntryID) -> String {
    visibleTextByEntryID[entryID] ?? ""
  }

  func characterCount(for record: PersistedJournalEntryRecord) -> Int {
    calendarCharacterCounts[JournalLogicalDayKey(record.day.logicalDate)] ?? 0
  }

  func configure(repository: any JournalEntryRepository) {
    self.repository = repository
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await reload()
  }

  func reload() async {
    guard let repository else { return }
    hasLoaded = true
    do {
      let records = try await repository.recentEntries(limit: 10_000)
      let projection = await Task.detached(priority: .utility) {
        JournalHistoryProjection(records: records)
      }.value
      entries = projection.entries
      visibleTextByEntryID = projection.visibleTextByEntryID
      calendarCharacterCounts = projection.characterCounts
      rebuildDerivedPresentations(recomputesCharacterCounts: false)
      status = entries.isEmpty ? "还没有可回顾的日记" : "已载入 \(entries.count) 天日记"
    } catch {
      status = "读取日记历史失败"
    }
  }

  func integrate(_ record: PersistedJournalEntryRecord) {
    entries.removeAll { $0.day.id == record.day.id }
    let visibleBody = JournalMarkdownText.visibleText(in: record.currentOriginal.body)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    visibleTextByEntryID[record.entry.id] = visibleBody
    let dayKey = JournalLogicalDayKey(record.day.logicalDate)
    if !visibleBody.isEmpty {
      entries.append(record)
      entries.sort { lhs, rhs in
        if lhs.entry.updatedAt != rhs.entry.updatedAt {
          return lhs.entry.updatedAt > rhs.entry.updatedAt
        }
        return lhs.day.boundary.startsAt > rhs.day.boundary.startsAt
      }
      calendarCharacterCounts[dayKey] = JournalMarkdownText.characterCount(
        inVisibleText: visibleBody
      )
    } else {
      calendarCharacterCounts[dayKey] = nil
    }
    rebuildDerivedPresentations(recomputesCharacterCounts: false)
    status = entries.isEmpty ? "还没有可回顾的日记" : "已载入 \(entries.count) 天日记"
  }

  private func rebuildDerivedPresentations(
    now: Date = .now,
    recomputesCharacterCounts: Bool = true
  ) {
    if recomputesCharacterCounts {
      calendarCharacterCounts = Dictionary(
        entries.map {
          (
            JournalLogicalDayKey($0.day.logicalDate),
            JournalMarkdownText.characterCount(in: $0.currentOriginal.body)
          )
        },
        uniquingKeysWith: max
      )
    }
    statistics = JournalWritingStatistics(
      entries: entries,
      characterCounts: calendarCharacterCounts
    )
    heatmapPresentation = JournalWritingHeatmapPresentation(
      characterCounts: calendarCharacterCounts,
      endingAt: now
    )
  }
}

private struct JournalHistoryProjection: Sendable {
  let entries: [PersistedJournalEntryRecord]
  let visibleTextByEntryID: [JournalEntryID: String]
  let characterCounts: [JournalLogicalDayKey: Int]

  init(records: [PersistedJournalEntryRecord]) {
    var retained: [PersistedJournalEntryRecord] = []
    var visible: [JournalEntryID: String] = [:]
    var counts: [JournalLogicalDayKey: Int] = [:]
    retained.reserveCapacity(records.count)
    visible.reserveCapacity(records.count)
    counts.reserveCapacity(records.count)
    for record in records {
      let text = JournalMarkdownText.visibleText(in: record.currentOriginal.body)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      visible[record.entry.id] = text
      guard !text.isEmpty else { continue }
      retained.append(record)
      counts[JournalLogicalDayKey(record.day.logicalDate)] =
        JournalMarkdownText.characterCount(inVisibleText: text)
    }
    entries = retained
    visibleTextByEntryID = visible
    characterCounts = counts
  }
}

struct JournalWritingStatistics: Equatable {
  let totalCharacterCount: Int
  let writingDayCount: Int
  let currentStreak: Int

  init(entries: [PersistedJournalEntryRecord]) {
    self.init(
      entries: entries,
      characterCounts: Dictionary(
        entries.map {
          (
            JournalLogicalDayKey($0.day.logicalDate),
            JournalMarkdownText.characterCount(in: $0.currentOriginal.body)
          )
        },
        uniquingKeysWith: max
      )
    )
  }

  init(
    entries: [PersistedJournalEntryRecord],
    characterCounts: [JournalLogicalDayKey: Int]
  ) {
    let writtenEntries = entries.filter {
      characterCounts[JournalLogicalDayKey($0.day.logicalDate)] != nil
    }
    writingDayCount = writtenEntries.count
    totalCharacterCount = characterCounts.values.reduce(0, +)
    let distinctDays = Set(
      writtenEntries.map { record in
        "\(record.day.logicalDate.year)-\(record.day.logicalDate.month)-"
          + "\(record.day.logicalDate.day)"
      })
    let orderedDays = writtenEntries.map(\.day).sorted {
      $0.boundary.startsAt > $1.boundary.startsAt
    }
    guard let latest = orderedDays.first else {
      currentStreak = 0
      return
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: latest.timeZoneIdentifier) ?? .autoupdatingCurrent
    var cursor = calendar.startOfDay(for: latest.boundary.startsAt)
    var streak = 0
    while true {
      let components = calendar.dateComponents([.year, .month, .day], from: cursor)
      guard let year = components.year, let month = components.month, let day = components.day,
        distinctDays.contains("\(year)-\(month)-\(day)")
      else { break }
      streak += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = previous
    }
    currentStreak = streak
  }
}

struct JournalWritingHeatmapCell: Identifiable, Equatable {
  let date: Date
  let characterCount: Int
  let hasEntry: Bool
  let isFuture: Bool

  var id: Date { date }
}

struct JournalWritingHeatmapPresentation: Equatable {
  let cells: [JournalWritingHeatmapCell]
  let weekCount: Int
  let maximumCharacterCount: Int

  init(
    entries: [PersistedJournalEntryRecord],
    endingAt: Date,
    weekCount: Int = 26,
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
  ) {
    self.init(
      characterCounts: Dictionary(
        entries.map {
          (
            JournalLogicalDayKey($0.day.logicalDate),
            JournalMarkdownText.characterCount(in: $0.currentOriginal.body)
          )
        },
        uniquingKeysWith: max
      ),
      endingAt: endingAt,
      weekCount: weekCount,
      calendar: sourceCalendar
    )
  }

  init(
    characterCounts countsByDay: [JournalLogicalDayKey: Int],
    endingAt: Date,
    weekCount: Int = 26,
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
  ) {
    let safeWeekCount = max(1, weekCount)
    var calendar = sourceCalendar
    calendar.firstWeekday = 2
    let today = calendar.startOfDay(for: endingAt)
    let weekday = calendar.component(.weekday, from: today)
    let daysSinceMonday = (weekday - calendar.firstWeekday + 7) % 7
    let currentMonday =
      calendar.date(
        byAdding: .day,
        value: -daysSinceMonday,
        to: today
      ) ?? today
    let firstMonday =
      calendar.date(
        byAdding: .day,
        value: -(safeWeekCount - 1) * 7,
        to: currentMonday
      ) ?? currentMonday
    cells = (0..<(safeWeekCount * 7)).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: firstMonday) else {
        return nil
      }
      let components = calendar.dateComponents(
        [.year, .month, .day],
        from: date
      )
      let key = JournalLogicalDayKey(
        year: components.year ?? 0,
        month: components.month ?? 0,
        day: components.day ?? 0
      )
      let count = countsByDay[key] ?? 0
      return JournalWritingHeatmapCell(
        date: date,
        characterCount: count,
        hasEntry: countsByDay[key] != nil,
        isFuture: date > today
      )
    }
    self.weekCount = safeWeekCount
    maximumCharacterCount = cells.map(\.characterCount).max() ?? 0
  }
}

struct JournalLogicalDayKey: Hashable, Sendable {
  let year: Int
  let month: Int
  let day: Int

  init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  init(_ date: LogicalDayDate) {
    self.init(year: date.year, month: date.month, day: date.day)
  }
}

/// Statistics and search previews should describe what a person wrote, rather
/// than the Markdown scaffolding that makes it render. This intentionally
/// stays small and deterministic: it is not a Markdown renderer.
enum JournalMarkdownText {
  private static let image = try! NSRegularExpression(
    pattern: #"!\[[^\]]*\]\([^\)]*\)"#
  )
  private static let link = try! NSRegularExpression(
    pattern: #"\[([^\]]*)\]\([^\)]*\)"#
  )
  private static let blockPrefix = try! NSRegularExpression(
    pattern: #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s?|[-+*]\s+|\d+[.)]\s+)"#
  )

  static func visibleText(in markdown: String) -> String {
    let fullRange = NSRange(markdown.startIndex..., in: markdown)
    let withoutImages = image.stringByReplacingMatches(
      in: markdown, range: fullRange, withTemplate: ""
    )
    let linkRange = NSRange(withoutImages.startIndex..., in: withoutImages)
    let withoutLinkDestinations = link.stringByReplacingMatches(
      in: withoutImages, range: linkRange, withTemplate: "$1"
    )
    let prefixRange = NSRange(withoutLinkDestinations.startIndex..., in: withoutLinkDestinations)
    let withoutBlockPrefixes = blockPrefix.stringByReplacingMatches(
      in: withoutLinkDestinations, range: prefixRange, withTemplate: ""
    )
    return
      withoutBlockPrefixes
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: "~~", with: "")
  }

  static func characterCount(in markdown: String) -> Int {
    characterCount(inVisibleText: visibleText(in: markdown))
  }

  static func characterCount(inVisibleText text: String) -> Int {
    text.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }.count
  }
}
