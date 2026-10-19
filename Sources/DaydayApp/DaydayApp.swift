import AppKit
import Darwin
import DaydayAI
import DaydayCapture
import DaydayCore
import DaydayIntegrations
import DaydayStorage
import DaydayUnderstanding
import SwiftUI

@MainActor
final class DaydayApplicationDelegate: NSObject, NSApplicationDelegate {
  private var shutdownHandler: (@MainActor @Sendable () async -> Void)?
  private var mainWindowOpener: (@MainActor () -> Void)?
  private var isTerminationPending = false
  private var menuBarPopoverController: MenuBarPopoverController?

  func installShutdownHandler(
    _ handler: @escaping @MainActor @Sendable () async -> Void
  ) {
    shutdownHandler = handler
  }

  func installMenuBarPopover(
    runtime: AppRuntimeModel,
    permissionOnboarding: PermissionOnboardingModel,
    timeline: MenuBarTimelineModel,
    insights: MenuBarInsightsModel,
    appearance: AppearanceSettingsModel,
    onOpenToday: @escaping @MainActor () -> Void
  ) {
    guard menuBarPopoverController == nil else { return }
    menuBarPopoverController = MenuBarPopoverController(
      runtime: runtime,
      permissionOnboarding: permissionOnboarding,
      timeline: timeline,
      insights: insights,
      appearance: appearance,
      onOpenToday: onOpenToday
    )
  }

  func installMainWindowOpener(_ opener: @escaping @MainActor () -> Void) {
    mainWindowOpener = opener
  }

  func openMainWindow() {
    DaydayWindowCoordinator.openMainWindow { [mainWindowOpener] in mainWindowOpener?() }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let shutdownHandler else { return .terminateNow }
    guard !isTerminationPending else { return .terminateLater }
    isTerminationPending = true
    Task { @MainActor in
      await shutdownHandler()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Dayday is a menu-bar resident application. Closing its only document window must preserve
  /// collection and leave the status-item entry point available; explicit quit remains the only
  /// path that requests process termination.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    DaydayWindowCoordinator.bringExistingMainWindowForward(in: sender)
  }
}

@MainActor
enum DaydayWindowCoordinator {
  static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("dayday.main-window")

  /// `openWindow` can enqueue scene creation without activating a menu-bar application. Activate
  /// before opening, then retry on subsequent main-loop turns until SwiftUI installs the NSWindow.
  static func openMainWindow(_ open: () -> Void) {
    let application = NSApplication.shared
    application.activate(ignoringOtherApps: true)
    open()
    bringMainWindowForward(in: application, attemptsRemaining: 3)
  }

  static func bringExistingMainWindowForward(in application: NSApplication) -> Bool {
    application.activate(ignoringOtherApps: true)
    guard let window = mainWindow(in: application) else { return false }
    window.makeKeyAndOrderFront(nil)
    return true
  }

  static func requestTermination() {
    NSApplication.shared.terminate(nil)
  }

  private static func bringMainWindowForward(
    in application: NSApplication,
    attemptsRemaining: Int
  ) {
    if let window = mainWindow(in: application) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard attemptsRemaining > 0 else { return }
    DispatchQueue.main.async {
      bringMainWindowForward(
        in: application,
        attemptsRemaining: attemptsRemaining - 1
      )
    }
  }

  private static func mainWindow(in application: NSApplication) -> NSWindow? {
    application.windows.first { $0.identifier == mainWindowIdentifier }
  }
}

@main
struct DaydayApp: App {
  @NSApplicationDelegateAdaptor(DaydayApplicationDelegate.self)
  private var applicationDelegate
  @StateObject private var composition: DaydayAppComposition

  init() {
    let composition = DaydayAppComposition()
    _composition = StateObject(wrappedValue: composition)
    let delegate = applicationDelegate
    delegate.installShutdownHandler {
      await composition.shutdown()
    }
    delegate.installMenuBarPopover(
      runtime: composition.runtime,
      permissionOnboarding: composition.menuBarPermissionModel,
      timeline: composition.menuBarTimeline,
      insights: composition.menuBarInsights,
      appearance: composition.appearance,
      onOpenToday: {
        delegate.openMainWindow()
      }
    )
  }

  var body: some Scene {
    Window("Dayday", id: "main") {
      RootView(
        runtime: composition.runtime,
        weather: composition.weather,
        dailyWorkScheduleSettings: composition.dailyWorkScheduleSettings,
        inputInsights: composition.inputInsights,
        applicationUsageInsights: composition.applicationUsageInsights,
        permissionOnboarding: composition.mainWindowPermissionModel,
        appearance: composition.appearance,
        providerSettings: composition.providerSettings,
        visionProviderSettings: composition.visionProviderSettings,
        diagnostics: composition.diagnostics,
        workReport: composition.workReport,
        historicalTimeline: composition.historicalTimeline,
        healthArchive: composition.healthArchive,
        journal: composition.journal,
        journalAI: composition.journalAI,
        journalHistory: composition.journalHistory,
        journalFragments: composition.journalFragments,
        journalAttachments: composition.journalAttachments,
        journalLocations: composition.journalLocations
      )
      .frame(minWidth: 840, minHeight: 600)
      .background(MainWindowChromeConfigurator().frame(width: 0, height: 0))
      .background(
        MenuBarMainWindowOpenerInstaller(applicationDelegate: applicationDelegate)
          .frame(width: 0, height: 0)
      )
    }
    .defaultSize(width: 1180, height: 760)
  }
}

private struct MenuBarMainWindowOpenerInstaller: View {
  @Environment(\.openWindow) private var openWindow
  let applicationDelegate: DaydayApplicationDelegate

  var body: some View {
    Color.clear.onAppear {
      applicationDelegate.installMainWindowOpener { openWindow(id: "main") }
    }
  }
}

/// Keep the window identity and unified title-bar treatment while leaving the
/// native toolbar owned by SwiftUI. NavigationSplitView, searchable content,
/// inspectors, and page actions all depend on that standard macOS surface.
private struct MainWindowChromeConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> MainWindowChromeView {
    MainWindowChromeView()
  }

  func updateNSView(_ nsView: MainWindowChromeView, context: Context) {
    nsView.configureWindowChrome()
  }
}

private final class MainWindowChromeView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindowChrome()
    DispatchQueue.main.async { [weak self] in
      self?.configureWindowChrome()
    }
  }

  func configureWindowChrome() {
    guard let window else { return }
    window.identifier = DaydayWindowCoordinator.mainWindowIdentifier
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.toolbar?.showsBaselineSeparator = false
  }
}

@MainActor
final class AppDraftStore: ObservableObject {
  @Published var workNote = "" {
    didSet {
      let boundedValue = WorkNoteFileStore.bounded(workNote)
      guard boundedValue == workNote else {
        workNote = boundedValue
        return
      }
      scheduleWorkNoteSave()
    }
  }

  @Published private(set) var workNotePersistenceError: WorkNotePersistenceError? = nil

  private let workNotePersistence: any WorkNotePersisting
  private let saveDelay: Duration
  private var pendingWorkNoteSave: Task<Void, Never>?

  init(
    workNotePersistence: any WorkNotePersisting = WorkNoteFileStore.applicationSupportStore(),
    saveDelay: Duration = .milliseconds(350)
  ) {
    self.workNotePersistence = workNotePersistence
    self.saveDelay = saveDelay
    do {
      workNote = try workNotePersistence.load()
    } catch let error as WorkNotePersistenceError {
      workNotePersistenceError = error
    } catch {
      workNotePersistenceError = .unreadable
    }
  }

  deinit {
    pendingWorkNoteSave?.cancel()
  }

  func flushPendingWorkNoteSave() {
    pendingWorkNoteSave?.cancel()
    pendingWorkNoteSave = nil
    saveWorkNote()
  }

  private func scheduleWorkNoteSave() {
    pendingWorkNoteSave?.cancel()
    let delay = saveDelay
    pendingWorkNoteSave = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.saveWorkNote()
    }
  }

  private func saveWorkNote() {
    pendingWorkNoteSave = nil
    do {
      try workNotePersistence.save(workNote)
      workNotePersistenceError = nil
    } catch let error as WorkNotePersistenceError {
      workNotePersistenceError = error
    } catch {
      workNotePersistenceError = .writeFailed
    }
  }
}

/// App-owned storage for the user-authored facts supplied to work-report generation.
/// This is deliberately separate from journal and captured-objective storage.
@MainActor
protocol WorkNotePersisting {
  func load() throws -> String
  func save(_ workNote: String) throws
}

enum WorkNotePersistenceError: Error, Equatable {
  case unreadable
  case corrupted
  case writeFailed
}

@MainActor
final class WorkNoteFileStore: WorkNotePersisting {
  static let maximumUTF8ByteCount = 16 * 1024

  private let directoryURL: URL?
  private let fileManager: FileManager
  private let fileName: String
  private let maximumStoredUTF8ByteCount: Int

  init(
    directoryURL: URL,
    fileManager: FileManager = .default,
    fileName: String = "work-note.txt",
    maximumUTF8ByteCount: Int = WorkNoteFileStore.maximumUTF8ByteCount
  ) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
    self.fileName = fileName
    self.maximumStoredUTF8ByteCount = maximumUTF8ByteCount
  }

  private init(
    unavailableWith fileManager: FileManager,
    fileName: String,
    maximumUTF8ByteCount: Int
  ) {
    directoryURL = nil
    self.fileManager = fileManager
    self.fileName = fileName
    self.maximumStoredUTF8ByteCount = maximumUTF8ByteCount
  }

  static func applicationSupportStore(
    fileManager: FileManager = .default,
    fileName: String = "work-note.txt",
    maximumUTF8ByteCount: Int = WorkNoteFileStore.maximumUTF8ByteCount
  ) -> WorkNoteFileStore {
    let directoryURL: URL?
    do {
      directoryURL = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      ).appendingPathComponent("Dayday", isDirectory: true)
    } catch {
      directoryURL = nil
    }
    guard let directoryURL else {
      return WorkNoteFileStore(
        unavailableWith: fileManager,
        fileName: fileName,
        maximumUTF8ByteCount: maximumUTF8ByteCount
      )
    }
    return WorkNoteFileStore(
      directoryURL: directoryURL,
      fileManager: fileManager,
      fileName: fileName,
      maximumUTF8ByteCount: maximumUTF8ByteCount
    )
  }

  func load() throws -> String {
    let directory = try openSecuredDirectory()
    defer { close(directory) }
    let descriptor = fileName.withCString {
      openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    if descriptor < 0, errno == ENOENT { return "" }
    guard descriptor >= 0 else { throw WorkNotePersistenceError.unreadable }
    defer { close(descriptor) }
    try secureExistingFile(descriptor)
    let data = try readBoundedData(from: descriptor)
    guard data.count <= maximumStoredUTF8ByteCount,
      let workNote = String(data: data, encoding: .utf8)
    else {
      throw WorkNotePersistenceError.corrupted
    }
    return workNote
  }

  func save(_ workNote: String) throws {
    let directory: Int32
    do {
      directory = try openSecuredDirectory()
    } catch {
      throw WorkNotePersistenceError.writeFailed
    }
    defer { close(directory) }
    let data = Data(
      Self.bounded(workNote, maximumUTF8ByteCount: maximumStoredUTF8ByteCount).utf8
    )
    try validateExistingFileBeforeReplacement(in: directory)
    let temporaryName = ".work-note-\(UUID().uuidString).tmp"
    let descriptor = temporaryName.withCString {
      openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else { throw WorkNotePersistenceError.writeFailed }
    defer {
      close(descriptor)
      _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
    }
    do {
      try writeAll(data, to: descriptor)
      guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
        throw WorkNotePersistenceError.writeFailed
      }
      try validateExistingFileBeforeReplacement(in: directory)
      guard temporaryName.withCString({ renameat(directory, $0, directory, fileName) }) == 0,
        fsync(directory) == 0
      else { throw WorkNotePersistenceError.writeFailed }
    } catch {
      throw WorkNotePersistenceError.writeFailed
    }
  }

  static func bounded(_ value: String) -> String {
    bounded(value, maximumUTF8ByteCount: maximumUTF8ByteCount)
  }

  private static func bounded(_ value: String, maximumUTF8ByteCount: Int) -> String {
    guard value.utf8.count > maximumUTF8ByteCount else { return value }
    var result = ""
    result.reserveCapacity(value.count)
    var byteCount = 0
    for character in value {
      let characterByteCount = String(character).utf8.count
      guard byteCount + characterByteCount <= maximumUTF8ByteCount else { break }
      result.append(character)
      byteCount += characterByteCount
    }
    return result
  }

  private func openSecuredDirectory() throws -> Int32 {
    guard let directoryURL else { throw WorkNotePersistenceError.unreadable }
    do {
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    } catch {
      throw WorkNotePersistenceError.unreadable
    }
    let descriptor = directoryURL.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw WorkNotePersistenceError.unreadable }
    do {
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        status.st_uid == geteuid(),
        fchmod(descriptor, 0o700) == 0
      else { throw WorkNotePersistenceError.unreadable }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private func validateExistingFileBeforeReplacement(in directory: Int32) throws {
    let descriptor = fileName.withCString {
      openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    if descriptor < 0, errno == ENOENT { return }
    guard descriptor >= 0 else { throw WorkNotePersistenceError.writeFailed }
    defer { close(descriptor) }
    do {
      try secureExistingFile(descriptor)
    } catch {
      throw WorkNotePersistenceError.writeFailed
    }
  }

  private func secureExistingFile(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_uid == geteuid(), status.st_nlink == 1,
      fchmod(descriptor, 0o600) == 0
    else { throw WorkNotePersistenceError.unreadable }
  }

  private func readBoundedData(from descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw WorkNotePersistenceError.unreadable }
      if count == 0 { return data }
      data.append(buffer, count: Int(count))
      guard data.count <= maximumStoredUTF8ByteCount else {
        throw WorkNotePersistenceError.corrupted
      }
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        guard written > 0 else { throw WorkNotePersistenceError.writeFailed }
        pointer = pointer.advanced(by: written)
        remaining -= written
      }
    }
  }
}
