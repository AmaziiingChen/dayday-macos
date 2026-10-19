import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct JournalFragmentModelTests {
  @Test
  func addFragmentPersistsImmutableFragmentForCurrentDay() async throws {
    let repository = InMemoryJournalFragmentRepository()
    let model = JournalFragmentModel()
    model.configure(repository: repository)
    await model.refresh(now: fixedNow)

    model.draft = "  会议间隙记下的一点。  "
    await model.addFragment(now: fixedNow)

    #expect(model.fragments.count == 1)
    #expect(model.fragments[0].body == "会议间隙记下的一点。")
    #expect(await repository.onlyFragment?.body == "会议间隙记下的一点。")
    #expect(model.draft == "")
    #expect(model.status.contains("已保存"))
  }

  @Test
  func blankDraftsAreIgnored() async throws {
    let repository = InMemoryJournalFragmentRepository()
    let model = JournalFragmentModel()
    model.configure(repository: repository)
    await model.refresh(now: fixedNow)

    model.draft = "   \n  "
    await model.addFragment(now: fixedNow)
    #expect(model.fragments.isEmpty)
    await waitFor({ await repository.isEmpty })
    #expect(model.draft == "   \n  ")
  }

  @Test
  func refreshLoadsTheCurrentDayFragments() async throws {
    let repository = InMemoryJournalFragmentRepository()
    let model = JournalFragmentModel()
    model.configure(repository: repository)
    await model.refresh(now: fixedNow)

    model.draft = "第一条"
    await model.addFragment(now: fixedNow)
    await waitFor({ await repository.count == 1 })
    model.draft = "第二条"
    await model.addFragment(now: fixedNow.addingTimeInterval(10))
    await waitFor({ await repository.count == 2 })

    let refreshed = JournalFragmentModel()
    refreshed.configure(repository: repository)
    await refreshed.refresh(now: fixedNow)
    #expect(refreshed.fragments.map(\.body) == ["第一条", "第二条"])
  }

  private var fixedNow: Date {
    Date(timeIntervalSince1970: 1_785_736_800)
  }

  private func waitFor(
    _ condition: @escaping () async -> Bool,
    timeout: Duration = .seconds(2)
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      if await condition() { return }
      if ContinuousClock.now > deadline {
        Issue.record("Timed out waiting for journal fragment condition")
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor InMemoryJournalFragmentRepository: JournalFragmentRepository {
  private var items: [JournalFragment] = []

  var isEmpty: Bool { items.isEmpty }
  var count: Int { items.count }
  var onlyFragment: JournalFragment? { items.first }

  func insert(_ fragment: JournalFragment) async throws -> JournalFragmentInsertResult {
    guard !items.contains(fragment) else { return .alreadyPresent }
    items.append(fragment)
    items.sort {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
    }
    return .inserted
  }

  func fragments(for dayID: DayID) async throws -> [JournalFragment] {
    items.filter { $0.dayID == dayID }
  }

  func recentFragments(limit: Int) async throws -> [JournalFragment] {
    Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
  }

  func schemaVersion() async throws -> Int { 1 }
  func schemaFingerprint() async throws -> String { "test" }
}
