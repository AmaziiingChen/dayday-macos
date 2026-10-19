import Foundation
import Testing

@testable import DaydayCore

struct WorkReportJournalIsolationTests {
  @Test
  func logicalDayRetainsCivilDateTimeZoneAndBoundarySnapshot() throws {
    let descriptor = try makeDay()
    let expectedDate = try LogicalDayDate(year: 2026, month: 8, day: 1)

    #expect(descriptor.logicalDate == expectedDate)
    #expect(descriptor.timeZoneIdentifier == "Asia/Shanghai")
    #expect(descriptor.boundary.hour == 4)
    #expect(descriptor.boundary.endsAt.timeIntervalSince(descriptor.boundary.startsAt) == 86_400)

    #expect(
      throws: LogicalDayDate.ValidationError.invalidGregorianDate(
        year: 2026,
        month: 2,
        day: 29
      )
    ) {
      try LogicalDayDate(year: 2026, month: 2, day: 29)
    }
    #expect(throws: DayDescriptor.ValidationError.invalidIANATimeZone("Mars/Olympus")) {
      try DayDescriptor(
        logicalDate: LogicalDayDate(year: 2026, month: 8, day: 1),
        timeZoneIdentifier: "Mars/Olympus",
        boundary: WorkdayBoundarySnapshot(
          hour: 4,
          startsAt: instant("2026-07-31T20:00:00Z"),
          endsAt: instant("2026-08-01T20:00:00Z")
        )
      )
    }

    let springForward = try DayDescriptor(
      logicalDate: LogicalDayDate(year: 2026, month: 3, day: 8),
      timeZoneIdentifier: "America/Los_Angeles",
      boundary: WorkdayBoundarySnapshot(
        hour: 2,
        startsAt: instant("2026-03-08T10:00:00Z"),
        endsAt: instant("2026-03-09T09:00:00Z")
      )
    )
    #expect(
      springForward.boundary.endsAt.timeIntervalSince(springForward.boundary.startsAt)
        == 23 * 3_600
    )
  }

  @Test
  func finalizedReportRejectsAutomaticReplacementButAcceptsExplicitUserRevision() throws {
    let reportID = WorkReportID()
    let first = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: 1,
      previousRevisionID: nil,
      body: "完成了本地采集合同。",
      origin: .model,
      modelProvenance: modelProvenance(),
      createdAt: instant("2026-08-01T10:00:00Z")
    )
    let draft = try WorkReport(
      id: reportID,
      dayID: DayID(),
      initialRevision: first,
      createdAt: instant("2026-08-01T09:00:00Z")
    )
    let finalized = try draft.finalizedByUser(at: instant("2026-08-01T11:00:00Z"))
    let candidate = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: 2,
      previousRevisionID: first.id,
      body: "新增活动后的候选版本。",
      origin: .model,
      modelProvenance: modelProvenance(),
      createdAt: instant("2026-08-01T12:00:00Z")
    )

    #expect(throws: WorkReport.ValidationError.confirmedReportRequiresUserAcceptance) {
      try finalized.accepting(
        candidate,
        initiatedBy: .automatic,
        at: instant("2026-08-01T13:00:00Z")
      )
    }
    #expect(finalized.currentRevisionID == first.id)

    let accepted = try finalized.accepting(
      candidate,
      initiatedBy: .user,
      at: instant("2026-08-01T13:00:00Z")
    )
    #expect(accepted.currentRevisionID == candidate.id)
    #expect(accepted.status == .final)
  }

  @Test
  func journalPreservesExactUserOriginalAndKeepsAIDerivationSeparate() throws {
    let entryID = JournalEntryID()
    let exactOriginal = "  今天，嗯…… typoO 没改。\n\n"
    let original = try JournalOriginalVersion(
      journalEntryID: entryID,
      versionNumber: 1,
      previousVersionID: nil,
      body: exactOriginal,
      savedAt: instant("2026-08-01T08:01:00Z")
    )
    let entry = try JournalEntry(
      id: entryID,
      dayID: DayID(),
      initialOriginal: original,
      createdAt: instant("2026-08-01T08:00:00Z")
    )
    let derived = try JournalDerivedVersion(
      journalEntryID: entryID,
      sourceOriginalVersionID: original.id,
      operation: .organize,
      body: "AI 整理后的副本。",
      modelProvenance: modelProvenance(),
      createdAt: instant("2026-08-01T08:02:00Z")
    )

    #expect(original.body == exactOriginal)
    #expect(entry.currentOriginalVersionID == original.id)
    #expect(derived.sourceOriginalVersionID == original.id)
    #expect(derived.body != original.body)

    let userEdit = try JournalOriginalVersion(
      journalEntryID: entryID,
      versionNumber: 2,
      previousVersionID: original.id,
      body: exactOriginal + "下午补了一句。",
      savedAt: instant("2026-08-01T14:00:00Z")
    )
    let editedEntry = try entry.acceptingUserEdit(userEdit)
    #expect(editedEntry.currentOriginalVersionID == userEdit.id)
  }

  @Test
  func attachmentContractIsClosedToRelativeImagesAndWebLinks() throws {
    let image = try JournalImageAttachment(
      relativeFileKey: JournalRelativeFileKey(
        rawValue: "journal/2026/08/photo.heic"
      ),
      mediaType: .heic,
      pixelWidth: 1_200,
      pixelHeight: 900,
      byteCount: 250_000
    )
    let link = try JournalLinkAttachment(
      url: #require(URL(string: "https://example.com/thought")),
      title: "参考链接"
    )

    #expect(JournalAttachmentPayload.image(image) != JournalAttachmentPayload.link(link))
    #expect(throws: JournalRelativeFileKey.ValidationError.invalidValue) {
      try JournalRelativeFileKey(rawValue: "/absolute/private.png")
    }
    #expect(throws: JournalLinkAttachment.ValidationError.unsupportedURL) {
      try JournalLinkAttachment(url: URL(fileURLWithPath: "/tmp/private.txt"))
    }
    let encoded = try JSONEncoder().encode(image)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["relativeFileKey"] = "/absolute/decoded-private.png"
    let forged = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: JournalRelativeFileKey.ValidationError.invalidValue) {
      try JSONDecoder().decode(JournalImageAttachment.self, from: forged)
    }
  }

  @Test
  func moodUsesAClosedUserAuthoredFivePointScale() throws {
    let middle = try MoodLevel(rawValue: 3)
    let encoded = try JSONEncoder().encode(middle)
    let decoded = try JSONDecoder().decode(MoodLevel.self, from: encoded)
    let entry = try MoodEntry(
      dayID: DayID(),
      observedAt: instant("2026-08-01T12:00:00Z"),
      pleasantness: middle,
      energy: MoodLevel(rawValue: 4),
      labels: ["平静"],
      reason: "午后记录",
      scope: .life
    )

    #expect(decoded == middle)
    #expect(entry.source == .user)
    #expect(throws: MoodLevel.ValidationError.outsideClosedScale(0)) {
      try MoodLevel(rawValue: 0)
    }
    #expect(throws: MoodLevel.ValidationError.outsideClosedScale(6)) {
      try MoodLevel(rawValue: 6)
    }
  }

  @Test
  func workReportContextSerializesOnlyTheExplicitWorkAllowlist() throws {
    let day = try makeDay()
    let visualObservationID = VisibleContentObservationID()
    let activity = try WorkReportActivityContext(
      id: ActivityID(),
      startedAt: instant("2026-08-01T01:00:00Z"),
      endedAt: instant("2026-08-01T02:00:00Z"),
      title: "实现合同",
      detectedInteractionSeconds: 1_800,
      evidenceFrameIDs: [EvidenceFrameID()],
      visibleContentObservationIDs: [visualObservationID]
    )
    let weather = try makeWeather(dayID: day.id)
    let objectiveEventID = EventID()
    let objectiveSegment = try WorkReportObjectiveApplicationSegment(
      startedAt: instant("2026-08-01T00:30:00Z"),
      endedAt: instant("2026-08-01T01:00:00Z"),
      applicationLabel: "WeChat",
      windowTitle: "产品研发群 · 陈工",
      objectiveEventIDs: [objectiveEventID]
    )
    let context = try WorkReportContext(
      day: day,
      activities: [activity],
      objectiveApplicationSegments: [objectiveSegment],
      workNotes: [
        try WorkReportNoteContext(
          id: WorkNoteID(),
          createdAt: instant("2026-08-01T02:01:00Z"),
          body: "完成隔离测试",
          activityID: activity.id
        )
      ],
      confirmedTodos: [
        try ConfirmedTodoContext(
          id: TodoItemID(),
          title: "运行 Core 测试",
          state: .done,
          completedAt: instant("2026-08-01T03:00:00Z"),
          activityID: activity.id
        )
      ],
      weatherSnapshots: [weather]
    )
    let data = try JSONEncoder().encode(context)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let expectedKeys: Set<String> = [
      "day", "activities", "workNotes", "calendarItems", "reminders",
      "confirmedTodos", "weatherSnapshots", "visualSegments", "objectiveApplicationSegments",
    ]

    #expect(Set(object.keys) == expectedKeys)
    #expect(context.sourceReferences.activityIDs == [activity.id])
    #expect(context.sourceReferences.objectiveEventIDs == [objectiveEventID])
    #expect(context.sourceReferences.weatherSnapshotIDs == [weather.id])
    #expect(context.sourceReferences.visibleContentObservationIDs == [visualObservationID])

    let serialized = try #require(String(data: data, encoding: .utf8)).lowercased()
    #expect(!serialized.contains("journal"))
    #expect(!serialized.contains("fragment"))
    #expect(!serialized.contains("attachment"))
    #expect(!serialized.contains("inferenceorigin"))
    #expect(!serialized.contains("redactionstate"))
    #expect(!serialized.contains("textproduction"))
    #expect(!serialized.contains("derivedversion"))
    #expect(!serialized.contains("mood"))
    #expect(!serialized.contains("pleasantness"))
    #expect(!serialized.contains("energy"))
  }

  @Test
  func workReportSourceReferencesDecodeRecordsCreatedBeforeVisualLineage() throws {
    let current = WorkReportSourceReferences(activityIDs: [ActivityID()])
    let encoded = try JSONEncoder().encode(current)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "visibleContentObservationIDs")
    object.removeValue(forKey: "objectiveEventIDs")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(WorkReportSourceReferences.self, from: legacyData)

    #expect(decoded.activityIDs == current.activityIDs)
    #expect(decoded.visibleContentObservationIDs.isEmpty)
    #expect(decoded.objectiveEventIDs.isEmpty)
  }

  @Test
  func weatherIsCityLevelObjectiveContextAndMustMatchTheContextDay() throws {
    let day = try makeDay()
    let weather = try makeWeather(dayID: DayID())

    #expect(weather.location.displayName == "上海")
    #expect(throws: WorkReportContext.ValidationError.weatherBelongsToDifferentDay(weather.id)) {
      try WorkReportContext(day: day, weatherSnapshots: [weather])
    }
    #expect(throws: WeatherSnapshot.ValidationError.humidityOutsidePercentage(101)) {
      try WeatherSnapshot(
        dayID: day.id,
        location: city(),
        provider: "Open-Meteo",
        providerSchemaVersion: "1",
        observedAt: instant("2026-08-01T04:00:00Z"),
        retrievedAt: instant("2026-08-01T04:01:00Z"),
        humidityPercent: 101
      )
    }

    let valid = try makeWeather(dayID: day.id)
    let encoded = try JSONEncoder().encode(valid)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["humidityPercent"] = 101
    let forged = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WeatherSnapshot.ValidationError.humidityOutsidePercentage(101)) {
      try JSONDecoder().decode(WeatherSnapshot.self, from: forged)
    }
  }

  @Test
  func logicalDaySupportsLateBoundaryAndFallRepeatAndRejectsForgedDecode() throws {
    let lateBoundary = try DayDescriptor(
      logicalDate: LogicalDayDate(year: 2026, month: 8, day: 1),
      timeZoneIdentifier: "America/Los_Angeles",
      boundary: WorkdayBoundarySnapshot(
        hour: 23,
        startsAt: instant("2026-08-02T06:00:00Z"),
        endsAt: instant("2026-08-03T06:00:00Z")
      )
    )
    #expect(lateBoundary.boundary.hour == 23)

    let fallRepeat = try DayDescriptor(
      logicalDate: LogicalDayDate(year: 2026, month: 11, day: 1),
      timeZoneIdentifier: "America/Los_Angeles",
      boundary: WorkdayBoundarySnapshot(
        hour: 1,
        startsAt: instant("2026-11-01T08:00:00Z"),
        endsAt: instant("2026-11-02T09:00:00Z")
      )
    )
    #expect(
      fallRepeat.boundary.endsAt.timeIntervalSince(fallRepeat.boundary.startsAt) == 25 * 3_600)

    let forged = try corruptedEncoding(of: lateBoundary) { object in
      var boundary = try #require(object["boundary"] as? [String: Any])
      boundary["startsAt"] = instant("2026-08-01T06:00:00Z").timeIntervalSinceReferenceDate
      object["boundary"] = boundary
    }
    #expect(throws: DayDescriptor.ValidationError.boundaryDoesNotStartOnLogicalDate) {
      try JSONDecoder().decode(DayDescriptor.self, from: forged)
    }
  }

  @Test
  func workReportRevisionLineageIsStrictAndDecodeFailsClosed() throws {
    let reportID = WorkReportID()
    let first = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: 1,
      previousRevisionID: nil,
      body: "first",
      origin: .user,
      modelProvenance: nil,
      createdAt: instant("2026-08-01T01:00:00Z")
    )
    let report = try WorkReport(
      id: reportID,
      dayID: DayID(),
      initialRevision: first,
      createdAt: instant("2026-08-01T00:00:00Z")
    )
    let skipped = try WorkReportRevision(
      reportID: reportID,
      revisionNumber: 3,
      previousRevisionID: first.id,
      body: "skip",
      origin: .user,
      modelProvenance: nil,
      createdAt: instant("2026-08-01T02:00:00Z")
    )
    #expect(throws: WorkReport.ValidationError.replacementRevisionNumberDoesNotFollowCurrent) {
      try report.accepting(
        skipped,
        initiatedBy: .user,
        at: instant("2026-08-01T03:00:00Z")
      )
    }

    let secondID = WorkReportRevisionID()
    #expect(throws: WorkReportRevision.ValidationError.selfReferentialPreviousRevision) {
      try WorkReportRevision(
        id: secondID,
        reportID: reportID,
        revisionNumber: 2,
        previousRevisionID: secondID,
        body: "cycle",
        origin: .user,
        modelProvenance: nil,
        createdAt: instant("2026-08-01T02:00:00Z")
      )
    }
    #expect(throws: WorkReport.ValidationError.initialRevisionMustBeFirst) {
      try WorkReport(
        id: reportID,
        dayID: DayID(),
        initialRevision: skipped,
        createdAt: instant("2026-08-01T00:00:00Z")
      )
    }

    let forged = try corruptedEncoding(of: report) { object in
      object["currentRevisionNumber"] = 0
    }
    #expect(throws: WorkReport.ValidationError.invalidCurrentRevisionNumber(0)) {
      try JSONDecoder().decode(WorkReport.self, from: forged)
    }

    let finalized = try report.finalizedByUser(at: instant("2026-08-01T02:00:00Z"))
    let invalidFinalization = try corruptedEncoding(of: finalized) { object in
      object["finalizedAt"] =
        instant("2026-08-01T00:30:00Z")
        .timeIntervalSinceReferenceDate
    }
    #expect(throws: WorkReport.ValidationError.invalidFinalizedAt) {
      try JSONDecoder().decode(WorkReport.self, from: invalidFinalization)
    }
  }

  @Test
  func journalOriginalLineageIsStrictAndDecodeFailsClosed() throws {
    let entryID = JournalEntryID()
    let first = try JournalOriginalVersion(
      journalEntryID: entryID,
      versionNumber: 1,
      previousVersionID: nil,
      body: " exact ",
      savedAt: instant("2026-08-01T01:00:00Z")
    )
    let entry = try JournalEntry(
      id: entryID,
      dayID: DayID(),
      initialOriginal: first,
      createdAt: instant("2026-08-01T00:00:00Z")
    )
    let skipped = try JournalOriginalVersion(
      journalEntryID: entryID,
      versionNumber: 3,
      previousVersionID: first.id,
      body: "skip",
      savedAt: instant("2026-08-01T02:00:00Z")
    )
    #expect(throws: JournalEntry.ValidationError.replacementVersionNumberDoesNotFollowCurrent) {
      try entry.acceptingUserEdit(skipped)
    }

    let secondID = JournalOriginalVersionID()
    #expect(throws: JournalOriginalVersion.ValidationError.selfReferentialPreviousVersion) {
      try JournalOriginalVersion(
        id: secondID,
        journalEntryID: entryID,
        versionNumber: 2,
        previousVersionID: secondID,
        body: "cycle",
        savedAt: instant("2026-08-01T02:00:00Z")
      )
    }
    #expect(throws: JournalEntry.ValidationError.initialVersionMustBeFirst) {
      try JournalEntry(
        id: entryID,
        dayID: DayID(),
        initialOriginal: skipped,
        createdAt: instant("2026-08-01T00:00:00Z")
      )
    }

    let forged = try corruptedEncoding(of: entry) { object in
      object["currentOriginalVersionNumber"] = 0
    }
    #expect(throws: JournalEntry.ValidationError.invalidCurrentOriginalVersionNumber(0)) {
      try JSONDecoder().decode(JournalEntry.self, from: forged)
    }
  }

  @Test
  func attachmentKeyMediaTypeAndPayloadDecodeAreClosed() throws {
    for invalid in [
      "/absolute.png", "../escape.png", "journal//empty.png",
      #"journal\..\escape.png"#, "C:drive.png", "journal/control\n.png",
    ] {
      #expect(throws: JournalRelativeFileKey.ValidationError.invalidValue) {
        try JournalRelativeFileKey(rawValue: invalid)
      }
    }

    let image = try JournalImageAttachment(
      relativeFileKey: JournalRelativeFileKey(rawValue: "journal/photo.png"),
      mediaType: .png,
      pixelWidth: 10,
      pixelHeight: 10,
      byteCount: 1
    )
    #expect(throws: JournalImageAttachment.ValidationError.invalidByteCount(0)) {
      try JournalImageAttachment(
        relativeFileKey: JournalRelativeFileKey(rawValue: "journal/empty.png"),
        mediaType: .png,
        pixelWidth: 10,
        pixelHeight: 10,
        byteCount: 0
      )
    }

    let unknownMedia = try corruptedEncoding(of: image) { object in
      object["mediaType"] = "image/svg+xml"
    }
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(JournalImageAttachment.self, from: unknownMedia)
    }
    let unknownPayload = Data(#"{"audio":{"_0":{}}}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(JournalAttachmentPayload.self, from: unknownPayload)
    }
  }

  @Test
  func workReportContextRejectsDuplicateAndUnknownLineage() throws {
    let day = try makeDay()
    let sharedEvent = EventID()
    let firstObjectiveSegment = try WorkReportObjectiveApplicationSegment(
      startedAt: instant("2026-08-01T00:30:00Z"),
      endedAt: instant("2026-08-01T01:00:00Z"),
      applicationLabel: "WeChat",
      objectiveEventIDs: [sharedEvent]
    )
    let secondObjectiveSegment = try WorkReportObjectiveApplicationSegment(
      startedAt: instant("2026-08-01T01:00:00Z"),
      endedAt: instant("2026-08-01T01:30:00Z"),
      applicationLabel: "Xcode",
      objectiveEventIDs: [sharedEvent]
    )
    #expect(throws: WorkReportContext.ValidationError.duplicateObjectiveEvent(sharedEvent)) {
      try WorkReportContext(
        day: day,
        objectiveApplicationSegments: [firstObjectiveSegment, secondObjectiveSegment]
      )
    }
    let sharedEvidence = EvidenceFrameID()
    let first = try makeActivity(
      evidenceFrameIDs: [sharedEvidence]
    )
    let second = try makeActivity(
      startedAt: instant("2026-08-01T03:00:00Z"),
      endedAt: instant("2026-08-01T04:00:00Z"),
      evidenceFrameIDs: [sharedEvidence]
    )
    #expect(throws: WorkReportContext.ValidationError.duplicateActivity(first.id)) {
      try WorkReportContext(day: day, activities: [first, first])
    }
    #expect(throws: WorkReportContext.ValidationError.duplicateEvidenceFrame(sharedEvidence)) {
      try WorkReportContext(day: day, activities: [first, second])
    }

    let sharedObservation = VisibleContentObservationID()
    let firstVisual = try makeActivity(visibleContentObservationIDs: [sharedObservation])
    let secondVisual = try makeActivity(
      startedAt: instant("2026-08-01T03:00:00Z"),
      endedAt: instant("2026-08-01T04:00:00Z"),
      visibleContentObservationIDs: [sharedObservation]
    )
    #expect(
      throws: WorkReportContext.ValidationError.duplicateVisibleContentObservation(
        sharedObservation
      )
    ) {
      try WorkReportContext(day: day, activities: [firstVisual, secondVisual])
    }

    let note = try WorkReportNoteContext(
      id: WorkNoteID(),
      createdAt: instant("2026-08-01T02:00:00Z"),
      body: "work",
      activityID: ActivityID()
    )
    let noteActivityID = try #require(note.activityID)
    #expect(
      throws: WorkReportContext.ValidationError.workNoteReferencesUnknownActivity(
        note.id,
        noteActivityID
      )
    ) {
      try WorkReportContext(day: day, workNotes: [note])
    }

    let todo = try ConfirmedTodoContext(
      id: TodoItemID(),
      title: "done",
      state: .done,
      completedAt: instant("2026-08-01T03:00:00Z"),
      activityID: ActivityID()
    )
    let todoActivityID = try #require(todo.activityID)
    #expect(
      throws: WorkReportContext.ValidationError.todoReferencesUnknownActivity(
        todo.id,
        todoActivityID
      )
    ) {
      try WorkReportContext(day: day, confirmedTodos: [todo])
    }

    let duplicateNote = try WorkReportNoteContext(
      id: note.id,
      createdAt: note.createdAt,
      body: note.body
    )
    #expect(throws: WorkReportContext.ValidationError.duplicateWorkNote(note.id)) {
      try WorkReportContext(day: day, workNotes: [duplicateNote, duplicateNote])
    }
    let weather = try makeWeather(dayID: day.id)
    #expect(throws: WorkReportContext.ValidationError.duplicateWeatherSnapshot(weather.id)) {
      try WorkReportContext(day: day, weatherSnapshots: [weather, weather])
    }
  }

  @Test
  func workReportContextAppliesLogicalDayTimeRules() throws {
    let day = try makeDay()
    let crossingActivity = try makeActivity(
      startedAt: instant("2026-07-31T19:30:00Z"),
      endedAt: instant("2026-07-31T20:30:00Z")
    )
    _ = try WorkReportContext(day: day, activities: [crossingActivity])

    let overstatedCrossing = try makeActivity(
      startedAt: instant("2026-07-31T19:30:00Z"),
      endedAt: instant("2026-07-31T20:30:00Z"),
      detectedInteractionSeconds: 3_600
    )
    #expect(
      throws: WorkReportContext.ValidationError.activityInteractionExceedsLogicalDayOverlap(
        overstatedCrossing.id
      )
    ) {
      try WorkReportContext(day: day, activities: [overstatedCrossing])
    }

    let outsideActivity = try makeActivity(
      startedAt: instant("2026-08-01T20:00:00Z"),
      endedAt: instant("2026-08-01T21:00:00Z")
    )
    #expect(
      throws: WorkReportContext.ValidationError.activityOutsideLogicalDay(
        outsideActivity.id
      )
    ) {
      try WorkReportContext(day: day, activities: [outsideActivity])
    }

    let outsideNote = try WorkReportNoteContext(
      id: WorkNoteID(),
      createdAt: day.boundary.endsAt,
      body: "next day"
    )
    #expect(
      throws: WorkReportContext.ValidationError.workNoteOutsideLogicalDay(
        outsideNote.id
      )
    ) {
      try WorkReportContext(day: day, workNotes: [outsideNote])
    }

    let outsideCalendar = try AllowedWorkCalendarItem(
      id: WorkCalendarItemID(),
      title: "next day",
      startsAt: instant("2026-08-01T20:00:00Z"),
      endsAt: instant("2026-08-01T21:00:00Z"),
      isAllDay: false
    )
    #expect(
      throws: WorkReportContext.ValidationError.calendarItemDoesNotOverlapLogicalDay(
        outsideCalendar.id
      )
    ) {
      try WorkReportContext(day: day, calendarItems: [outsideCalendar])
    }

    let outsideReminder = try AllowedWorkReminder(
      id: WorkReminderItemID(),
      title: "next day",
      dueAt: day.boundary.endsAt
    )
    #expect(
      throws: WorkReportContext.ValidationError.reminderOutsideLogicalDay(
        outsideReminder.id
      )
    ) {
      try WorkReportContext(day: day, reminders: [outsideReminder])
    }

    let outsideTodo = try ConfirmedTodoContext(
      id: TodoItemID(),
      title: "next day",
      state: .done,
      completedAt: day.boundary.endsAt
    )
    #expect(throws: WorkReportContext.ValidationError.todoOutsideLogicalDay(outsideTodo.id)) {
      try WorkReportContext(day: day, confirmedTodos: [outsideTodo])
    }

    let outsideWeather = try makeWeather(
      dayID: day.id,
      observedAt: day.boundary.endsAt
    )
    #expect(
      throws: WorkReportContext.ValidationError.weatherObservationOutsideLogicalDay(
        outsideWeather.id
      )
    ) {
      try WorkReportContext(day: day, weatherSnapshots: [outsideWeather])
    }
  }

  @Test
  func workReportIntervalsRejectZeroDuration() throws {
    let instant = instant("2026-08-01T02:00:00Z")

    #expect(throws: WorkReportActivityContext.ValidationError.invalidInterval) {
      try makeActivity(startedAt: instant, endedAt: instant)
    }
    #expect(throws: AllowedWorkCalendarItem.ValidationError.invalidInterval) {
      try AllowedWorkCalendarItem(
        id: WorkCalendarItemID(),
        title: "zero duration",
        startsAt: instant,
        endsAt: instant,
        isAllDay: false
      )
    }
  }

  @Test
  func cityLocationUsesOpaqueIDAndRejectsPreciseOrUnboundedInputOnDecode() throws {
    let valid = try city()
    #expect(valid.providerLocationKey.rawValue == "open-meteo:shanghai")

    for invalidName in [
      "31.2304,121.4737",
      "世纪大道100号",
      "上海\n浦东",
      String(repeating: "城", count: 49),
    ] {
      #expect(throws: (any Error).self) {
        try CityWeatherLocation(
          id: CityWeatherLocationID(),
          displayName: invalidName,
          timeZoneIdentifier: "Asia/Shanghai",
          providerLocationKey: WeatherProviderLocationKey(rawValue: "provider:city")
        )
      }
    }
    #expect(throws: WeatherProviderLocationKey.ValidationError.invalidValue) {
      try WeatherProviderLocationKey(rawValue: "provider key with prose")
    }
    #expect(throws: WeatherProviderLocationKey.ValidationError.invalidValue) {
      try WeatherProviderLocationKey(rawValue: "31.2304:121.4737")
    }

    let forged = try corruptedEncoding(of: valid) { object in
      object["displayName"] = "31.2304,121.4737"
    }
    #expect(throws: CityWeatherLocation.ValidationError.suspectedPreciseLocation) {
      try JSONDecoder().decode(CityWeatherLocation.self, from: forged)
    }
  }
}

private func makeDay() throws -> DayDescriptor {
  try DayDescriptor(
    logicalDate: LogicalDayDate(year: 2026, month: 8, day: 1),
    timeZoneIdentifier: "Asia/Shanghai",
    boundary: WorkdayBoundarySnapshot(
      hour: 4,
      startsAt: instant("2026-07-31T20:00:00Z"),
      endsAt: instant("2026-08-01T20:00:00Z")
    )
  )
}

private func makeWeather(
  dayID: DayID,
  observedAt: Date = instant("2026-08-01T04:00:00Z")
) throws -> WeatherSnapshot {
  try WeatherSnapshot(
    dayID: dayID,
    location: city(),
    provider: "Open-Meteo",
    providerSchemaVersion: "1",
    observedAt: observedAt,
    retrievedAt: instant("2026-08-01T04:01:00Z"),
    condition: "多云",
    temperatureCelsius: 30,
    dailyLowCelsius: 27,
    dailyHighCelsius: 34,
    precipitationMillimeters: 0,
    humidityPercent: 68,
    windKilometersPerHour: 12
  )
}

private func city() throws -> CityWeatherLocation {
  let id = try #require(
    UUID(
      uuidString: "CCCCCCCC-0000-0000-0000-000000000001"
    ))
  return try CityWeatherLocation(
    id: CityWeatherLocationID(rawValue: id),
    displayName: "上海",
    timeZoneIdentifier: "Asia/Shanghai",
    providerLocationKey: WeatherProviderLocationKey(rawValue: "open-meteo:shanghai")
  )
}

private func makeActivity(
  id: ActivityID = ActivityID(),
  startedAt: Date = instant("2026-08-01T01:00:00Z"),
  endedAt: Date = instant("2026-08-01T02:00:00Z"),
  detectedInteractionSeconds: Double = 0,
  evidenceFrameIDs: [EvidenceFrameID] = [],
  visibleContentObservationIDs: [VisibleContentObservationID] = []
) throws -> WorkReportActivityContext {
  try WorkReportActivityContext(
    id: id,
    startedAt: startedAt,
    endedAt: endedAt,
    title: "activity",
    detectedInteractionSeconds: detectedInteractionSeconds,
    evidenceFrameIDs: evidenceFrameIDs,
    visibleContentObservationIDs: visibleContentObservationIDs
  )
}

private func corruptedEncoding<Value: Encodable>(
  of value: Value,
  mutate: (inout [String: Any]) throws -> Void
) throws -> Data {
  let encoded = try JSONEncoder().encode(value)
  var object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  try mutate(&object)
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func modelProvenance() throws -> ModelProvenance {
  try ModelProvenance(provider: "test", model: "test-model", promptVersion: "v1")
}

private func instant(_ value: String) -> Date {
  ISO8601DateFormatter().date(from: value)!
}
