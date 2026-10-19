import DaydayCore
import Foundation

/// App binding for the user's journal fragments. Fragments are immutable
/// personal artifacts: this model only appends and reads them, and nothing in
/// the work-report allowlist consumes them.
@MainActor
final class JournalFragmentModel: ObservableObject {
  @Published private(set) var fragments: [JournalFragment] = []
  @Published var draft = ""
  @Published private(set) var status = "日记碎片尚未连接本地存储"
  @Published private(set) var isReady = false

  private var repository: (any JournalFragmentRepository)?
  private var selectedDay: DayDescriptor?
  private var refreshGeneration = 0

  func configure(repository: any JournalFragmentRepository) {
    self.repository = repository
    isReady = true
    status = "可以记录零散想法"
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, refreshGeneration == 0 else { return }
      await refresh(now: .now)
    }
  }

  /// Reloads the current logical day's fragments. Call after bootstrap and
  /// whenever the user returns to the journal.
  func refresh(now: Date = .now) async {
    guard let repository else { return }
    do {
      let day = try Self.currentDay(at: now)
      await refresh(day: day, repository: repository)
    } catch {
      status = "读取本机碎片失败"
    }
  }

  func refresh(day: DayDescriptor) async {
    guard let repository else { return }
    await refresh(day: day, repository: repository)
  }

  /// Adds a user-authored fragment for the current day. Blank drafts are ignored.
  func addFragment(now: Date = .now) async {
    guard let repository else {
      status = "本地存储尚未就绪"
      return
    }
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let day = try selectedDay ?? Self.currentDay(at: now)
      let fragment = try JournalFragment(
        dayID: day.id,
        body: trimmed,
        createdAt: now
      )
      switch try await repository.insert(fragment) {
      case .inserted:
        fragments.append(fragment)
        fragments.sort {
          if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
          return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        draft = ""
        status = "已保存碎片"
      case .alreadyPresent:
        draft = ""
        status = "这条碎片已经存在"
      }
    } catch {
      status = "保存碎片失败；内容仍保留在输入框内"
    }
  }

  private func refresh(
    day: DayDescriptor,
    repository: any JournalFragmentRepository
  ) async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    selectedDay = day
    do {
      let fragments = try await repository.fragments(for: day.id)
      guard generation == refreshGeneration, selectedDay?.id == day.id else { return }
      self.fragments = fragments
      if fragments.isEmpty {
        status = "还没有碎片；写下第一条就会保存"
      } else {
        status = "已读取这一天的 \(fragments.count) 条碎片"
      }
    } catch {
      guard generation == refreshGeneration else { return }
      fragments = []
      status = "读取本机碎片失败"
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
