import AppKit
import Combine
import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct JournalEntryModelTests {
  @Test
  func autosavePersistsExactOriginalWithoutCreatingAutomaticVersions() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)
    await waitFor({ model.isReady })

    model.acceptEditorSnapshot("今天，嗯…… typoO 没改。\n\n")
    await model.flushPendingAutosave(now: fixedNow)
    await waitFor { await repository.current == "今天，嗯…… typoO 没改。\n\n" }

    #expect(model.currentOriginalVersionNumber == 1)
    let first = try #require(await repository.onlyRecord)
    #expect(first.currentOriginal.body == "今天，嗯…… typoO 没改。\n\n")

    model.acceptEditorSnapshot("今天，嗯…… typoO 没改。\n\n晚上补了一句。")
    await model.flushPendingAutosave(now: fixedNow.addingTimeInterval(100))
    await waitFor { await repository.current?.contains("晚上补了一句") == true }

    #expect(model.currentOriginalVersionNumber == 1)
    let originals = await repository.allOriginals
    #expect(originals.map(\.versionNumber) == [1])
    #expect(originals.first?.id == first.currentOriginal.id)
    #expect(originals.first?.body == "今天，嗯…… typoO 没改。\n\n晚上补了一句。")

    let saveCount = await repository.saveCallCount
    await model.flushPendingAutosave(now: fixedNow.addingTimeInterval(200))
    #expect(await repository.saveCallCount == saveCount)
  }

  @Test
  func repeatedEditorCheckpointsDoNotInvalidateSwiftUIAfterTheFirstSave() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)

    model.acceptEditorSnapshot("第一句")
    await model.flushPendingAutosave(now: fixedNow)
    await waitFor { await repository.current == "第一句" }

    var invalidationCount = 0
    let observation = model.objectWillChange.sink { invalidationCount += 1 }
    defer { observation.cancel() }

    model.acceptEditorSnapshot("第一句，继续输入")
    await model.flushPendingAutosave(now: fixedNow.addingTimeInterval(1))
    await waitFor { await repository.current == "第一句，继续输入" }

    #expect(invalidationCount == 0)
    #expect(model.body == "第一句，继续输入")
  }

  @Test
  func restoreLoadsThePersistedExactOriginal() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)

    model.acceptEditorSnapshot("  保留的空格不该被修掉。  ")
    await model.flushPendingAutosave(now: fixedNow)
    await waitFor { await repository.current != nil }

    let restored = JournalEntryModel(saveDelay: .milliseconds(1))
    restored.configure(repository: repository)
    await restored.restore(now: fixedNow)
    #expect(restored.body == "  保留的空格不该被修掉。  ")
    #expect(restored.status.contains("已恢复"))
    #expect(restored.currentOriginalVersionNumber == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect((await repository.allOriginals).map(\.versionNumber) == [1])
  }

  @Test
  func blankBodyDoesNotCreateANewDiaryEntry() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)

    model.acceptEditorSnapshot("   \n  ")
    await model.flushPendingAutosave(now: fixedNow)
    await waitFor { await repository.isEmpty }

    #expect(model.currentOriginalVersionNumber == 0)
    #expect(model.status.contains("还没有需要保存"))
  }

  @Test
  func clearingAnExistingBodyPersistsTheClearInsteadOfRestoringOldText() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)
    await waitFor({ model.isReady })

    model.acceptEditorSnapshot("这段内容随后会被清空")
    await model.flushPendingAutosave(now: fixedNow)
    await waitFor { await repository.current == "这段内容随后会被清空" }

    model.acceptEditorSnapshot("")
    await model.flushPendingAutosave(now: fixedNow.addingTimeInterval(1))
    await waitFor { await repository.current == "" }

    let restored = JournalEntryModel(saveDelay: .milliseconds(1))
    restored.configure(repository: repository)
    await restored.restore(now: fixedNow.addingTimeInterval(2))
    #expect(restored.body.isEmpty)
    #expect(restored.status.contains("已恢复"))
  }

  @Test
  func privateArtifactAnchorIsAdoptedByTheFirstSavedOriginal() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)

    let anchor = try await model.attachmentAnchor(now: fixedNow)
    model.acceptEditorSnapshot("先插入图片，再写正文。")
    await model.flushPendingAutosave(now: fixedNow)
    let record = try #require(await repository.onlyRecord)

    #expect(record.entry.id == anchor.entryID)
    #expect(record.entry.dayID == anchor.dayID)
  }

  @Test
  func privateArtifactAnchorDoesNotCrossLogicalDays() async throws {
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    let first = try await model.attachmentAnchor(now: fixedNow)
    let nextDay = fixedNow.addingTimeInterval(86_400)
    let second = try await model.attachmentAnchor(now: nextDay)

    #expect(first.dayID != second.dayID)
    #expect(first.entryID != second.entryID)
  }

  @Test
  func imageMarkdownReplacesTheCurrentEditorSelection() {
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.acceptEditorSnapshot("before selected after")
    let attachmentID = JournalAttachmentID(
      rawValue: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
    )
    let selection = NSRange(location: 7, length: 8)

    let nextSelection = model.insertImageReference(
      attachmentID: attachmentID,
      altText: "照片",
      at: selection
    )

    let inserted = [
      "before ![照片](dayday-attachment://",
      "01020304-0506-0708-090a-0b0c0d0e0f10) after",
    ].joined()
    let expectedSelection = (inserted as NSString).length - (" after" as NSString).length
    #expect(model.body == inserted)
    #expect(nextSelection.location == expectedSelection)
    #expect(nextSelection.length == 0)
    #expect(model.editorContentRevision == 1)
  }

  @Test
  func importedImagesKeepOriginalMetadataButUseABoundedEditorResource() throws {
    let width = 3_200
    let height = 1_800
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayday-journal-image-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url, options: .atomic)

    let prepared = try JournalImageImport.prepare(url)

    #expect(prepared.pixelWidth == width)
    #expect(prepared.pixelHeight == height)
    #expect(max(prepared.display.pixelWidth, prepared.display.pixelHeight) == 1_600)
    #expect(NSImage(data: prepared.display.data) != nil)
  }

  @Test
  func removingAnImageReferenceKeepsTheRestOfTheJournal() {
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    let attachmentID = JournalAttachmentID(
      rawValue: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
    )
    model.acceptEditorSnapshot(
      "前文 ![照片](dayday-attachment://01020304-0506-0708-090a-0b0c0d0e0f10) 后文"
    )

    model.removeImageReference(attachmentID)

    #expect(model.body == "前文  后文")
    #expect(model.editorContentRevision == 1)
  }

  @Test
  func selectingCalendarDaysFlushesAndEditsTheChosenJournalWithoutRecreatingTheEditor()
    async throws
  {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .seconds(30))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)

    let firstEditorRevision = model.editorContentRevision
    model.acceptEditorSnapshot("第一天尚未到自动保存时间")
    let nextDay = try #require(
      Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: fixedNow)
    )
    await model.selectCalendarDay(nextDay)

    #expect(model.body.isEmpty)
    #expect(model.editorContentRevision > firstEditorRevision)
    #expect(try await repository.recentEntries(limit: 10).count == 1)

    model.acceptEditorSnapshot("第二天的内容")
    await model.selectCalendarDay(fixedNow)

    #expect(model.body == "第一天尚未到自动保存时间")
    let records = try await repository.recentEntries(limit: 10)
    #expect(records.count == 2)
    #expect(
      Set(records.map(\.currentOriginal.body))
        == ["第一天尚未到自动保存时间", "第二天的内容"]
    )
  }

  @Test
  func calendarAcknowledgesRequestedDayBeforePersistenceAndLoadingFinish() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .seconds(30))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)
    let originalDay = try #require(model.selectedDay)
    model.acceptEditorSnapshot("仍在等待保存的正文")
    await repository.setEntryDelay(.milliseconds(80))
    let nextDay = try #require(
      Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: fixedNow)
    )

    let selection = Task { await model.selectCalendarDay(nextDay) }
    await waitFor { model.pendingSelectedDay != nil }

    #expect(model.isSwitchingDay)
    #expect(model.selectedDay?.id == originalDay.id)
    #expect(model.presentedDay?.id == model.pendingSelectedDay?.id)

    await selection.value
    #expect(model.pendingSelectedDay == nil)
    #expect(model.presentedDay?.id == model.selectedDay?.id)
    #expect(model.selectedDay?.id != originalDay.id)
  }

  @Test
  func writingHeatmapUsesVisibleCharacterCountsOnAContinuousCalendarGrid() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)
    model.acceptEditorSnapshot("## 标题\n\n正文 123")
    await model.flushPendingAutosave(now: fixedNow)

    let records = try await repository.recentEntries(limit: 10)
    let presentation = JournalWritingHeatmapPresentation(
      entries: records,
      endingAt: fixedNow,
      weekCount: 2
    )

    #expect(presentation.cells.count == 14)
    #expect(presentation.weekCount == 2)
    #expect(
      presentation.maximumCharacterCount
        == JournalMarkdownText.characterCount(in: "## 标题\n\n正文 123")
    )
    #expect(presentation.cells.filter(\.hasEntry).count == 1)
  }

  @Test
  func historyStatisticsDescribeLocalJournalRecords() async throws {
    let repository = InMemoryJournalRepository()
    let model = JournalEntryModel(saveDelay: .milliseconds(1))
    model.configure(repository: repository)
    await model.restore(now: fixedNow)
    await waitFor({ model.isReady })
    model.acceptEditorSnapshot("今天写了 123 个字符")
    await model.flushPendingAutosave(now: fixedNow)

    let history = JournalHistoryModel()
    history.configure(repository: repository)
    await history.loadIfNeeded()

    #expect(history.statistics.writingDayCount == 1)
    #expect(history.statistics.currentStreak == 1)
    #expect(history.statistics.totalCharacterCount > 0)
    let record = try #require(history.entries.first)
    #expect(
      history.calendarCharacterCounts[JournalLogicalDayKey(record.day.logicalDate)]
        == JournalMarkdownText.characterCount(in: record.currentOriginal.body)
    )
    #expect(history.heatmapPresentation.cells.filter(\.hasEntry).count == 1)
    history.searchText = "123"
    #expect(history.filteredEntries.count == 1)
  }

  @Test
  func statisticsExcludeMarkdownSyntaxAndAttachmentIdentifiers() {
    let visible = JournalMarkdownText.visibleText(
      in: "## 标题\n\n[可见链接](https://example.com/secret)\n\n"
        + "![照片](dayday-attachment://01020304-0506-0708-090a-0b0c0d0e0f10)"
    )

    #expect(visible.contains("标题"))
    #expect(visible.contains("可见链接"))
    #expect(!visible.contains("example.com"))
    #expect(!visible.contains("dayday-attachment"))
  }

  @Test
  func markdownExportReplacesPrivateAttachmentURLsWithRelativeResources() {
    let id = JournalAttachmentID(
      rawValue: UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!
    )
    let exported = JournalMarkdownExport.document(
      from: "![照片](dayday-attachment://01020304-0506-0708-090a-0b0c0d0e0f10)",
      resourcePaths: [id: "images/photo.jpg"],
      resourceDirectoryName: "日记.resources"
    )

    #expect(exported == "![照片](日记.resources/images/photo.jpg)")
  }

  @Test
  func nativeEditorContinuesIndentedListsUsingTheirExistingLevel() {
    #expect(
      JournalRichTextCodec.nextListItem(
        afterVisibleLine: "1. 第一项",
        style: "ordered",
        indent: 2,
        number: 1
      ) == "  2. "
    )
    #expect(
      JournalRichTextCodec.nextListItem(
        afterVisibleLine: "• 子项目",
        style: "bullet",
        indent: 2,
        number: nil
      ) == "  - "
    )
  }

  @Test
  func nativeEditorKeepsImageAspectRatioWithinAReadableMaximum() {
    let wide = NSImage(size: NSSize(width: 1_200, height: 600))
    let portrait = NSImage(size: NSSize(width: 600, height: 1_200))

    let wideBounds = JournalRichTextCodec.attachmentBounds(for: wide)
    let portraitBounds = JournalRichTextCodec.attachmentBounds(for: portrait)

    #expect(wideBounds.width == 360)
    #expect(wideBounds.height == 180)
    #expect(portraitBounds.width == 160)
    #expect(portraitBounds.height == 320)
  }

  @Test
  func nativeEditorPreservesReadableLinkTextAndDestination() {
    let source = [
      "查看 [Apple 手记](https://support.apple.com/guide/iphone/",
      "write-in-your-journal-iph6257be047/ios)",
    ].joined()
    let rendered = JournalRichTextCodec.render(source, images: [:])

    #expect(JournalRichTextCodec.markdown(from: rendered) == source)
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
        Issue.record("Timed out waiting for journal model condition")
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor InMemoryJournalRepository: JournalEntryRepository {
  private var records: [DayID: PersistedJournalEntryRecord] = [:]
  private var entryDelay: Duration = .zero
  private(set) var saveCallCount = 0

  var isEmpty: Bool { records.isEmpty }
  var current: String? { records.values.first?.currentOriginal.body }
  var onlyRecord: PersistedJournalEntryRecord? { records.values.first }
  var allOriginals: [JournalOriginalVersion] {
    records.values.map(\.currentOriginal)
  }

  func save(_ record: PersistedJournalEntryRecord) async throws -> JournalEntrySaveResult {
    saveCallCount += 1
    let result: JournalEntrySaveResult
    if let existing = records[record.entry.dayID] {
      result = existing == record ? .alreadyPresent : .updated
    } else {
      result = .inserted
    }
    records[record.entry.dayID] = record
    return result
  }

  func entry(for dayID: DayID) async throws -> PersistedJournalEntryRecord? {
    if entryDelay > .zero {
      try? await Task.sleep(for: entryDelay)
    }
    return records[dayID]
  }

  func setEntryDelay(_ delay: Duration) {
    entryDelay = delay
  }

  func originals(for dayID: DayID) async throws -> [JournalOriginalVersion] {
    records[dayID].map { [$0.currentOriginal] } ?? []
  }

  func recentEntries(limit: Int) async throws -> [PersistedJournalEntryRecord] {
    Array(records.values.sorted { $0.entry.updatedAt > $1.entry.updatedAt }.prefix(limit))
  }

  func schemaVersion() async throws -> Int { 1 }
  func schemaFingerprint() async throws -> String { "test" }
}
