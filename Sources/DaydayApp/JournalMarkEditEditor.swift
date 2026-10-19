import AppKit
import DaydayCore
import MarkEditCore
import MarkEditKit
import SwiftUI
import WebKit

/// The complete MarkEdit formatting surface remains available to Dayday while the journal toolbar
/// can disclose only the commands appropriate to the current writing context.
enum JournalMarkdownEditorAction: Equatable {
  case heading(Int)
  case bold
  case italic
  case strikethrough
  case bullet
  case ordered
  case task
  case quote
  case inlineCode
  case inlineMath
  case codeBlock
  case mathBlock
  case horizontalRule
  case link(title: String, url: String)
  case table
  case insertText(String)
  case indentLess
  case indentMore
  case moveLineUp
  case moveLineDown
  case copyLineUp
  case copyLineDown
  case undo
  case redo
  case sourceMode(Bool)
}

struct JournalMarkEditSelectionState: Equatable {
  var selectedText = ""
  var attachmentID: JournalAttachmentID?
}

struct DaydayMarkdownEditorTheme: Codable, Equatable {
  let accent: String
  let accentMuted: String
  let accentSubtle: String
  let scrollThumb: String
  let scrollThumbHover: String
  let placeholder: String

  init(theme: DaydayTheme, increasedContrast: Bool) {
    let accent = theme.primitive(.action)
    self.accent = accent.cssColor()
    accentMuted = accent.cssColor(opacity: increasedContrast ? 0.48 : 0.24)
    accentSubtle = accent.cssColor(opacity: increasedContrast ? 0.30 : 0.14)
    scrollThumb = accent.cssColor(opacity: increasedContrast ? 0.64 : 0.28)
    scrollThumbHover = accent.cssColor(opacity: increasedContrast ? 0.82 : 0.52)
    placeholder = theme.primitive(.textTertiary).cssColor()
  }
}

extension DaydayRGBA {
  fileprivate func cssColor(opacity overrideOpacity: Double? = nil) -> String {
    let red = Int((min(1, max(0, self.red)) * 255).rounded())
    let green = Int((min(1, max(0, self.green)) * 255).rounded())
    let blue = Int((min(1, max(0, self.blue)) * 255).rounded())
    let alpha = min(1, max(0, overrideOpacity ?? opacity))
    return "rgba(\(red), \(green), \(blue), \(String(format: "%.3f", alpha)))"
  }
}

enum JournalMarkEditState: Equatable {
  case loading
  case ready
  case failed
}

enum JournalMarkEditConfiguration {
  /// Tab should change the indentation of the current Markdown block. Inserting literal spaces at
  /// the caret breaks the standard editor expectation for nested ordered, bullet and task lists.
  static let tabKeyBehavior = TabKeyBehavior.indentMore.rawValue
  /// Four spaces are valid for ordered, bullet and mixed nested lists. Two spaces are not enough
  /// after a multi-character ordered-list marker under strict CommonMark parsing.
  static let indentUnit = "    "
}

struct JournalEditorInputUpdateDecision: Equatable {
  var publishesSelection = false
  var defersSelectionPublication = false
  var notifiesUserEdit = false
  var cancelsMarkdownSync = false
  var schedulesMarkdownSync = false
}

/// Keeps native state propagation out of an input method's marked-text session. CodeMirror owns
/// the provisional text until composition ends; publishing it through SwiftUI during candidate
/// selection can invalidate the host view and make WebKit repeatedly reconcile unfinished text.
struct JournalEditorInputSynchronizationState {
  private(set) var isComposing = false
  private var hasPendingCompositionEdit = false
  private var defersNextCompletedUpdate = false

  mutating func viewDidUpdate(
    contentEdited: Bool,
    compositionEnded: Bool
  ) -> JournalEditorInputUpdateDecision {
    guard compositionEnded else {
      isComposing = true
      hasPendingCompositionEdit = hasPendingCompositionEdit || contentEdited
      return .init(cancelsMarkdownSync: true)
    }

    let wasComposing = isComposing || hasPendingCompositionEdit || defersNextCompletedUpdate
    isComposing = false
    defersNextCompletedUpdate = false
    let shouldCommit = contentEdited || hasPendingCompositionEdit
    hasPendingCompositionEdit = false
    return .init(
      publishesSelection: !wasComposing,
      defersSelectionPublication: wasComposing,
      notifiesUserEdit: shouldCommit,
      schedulesMarkdownSync: shouldCommit
    )
  }

  mutating func compositionDidEnd() -> JournalEditorInputUpdateDecision {
    isComposing = false
    // WebKit may deliver MarkEdit's explicit composition-end callback either before or after the
    // final CodeMirror update. Keep the next completed update off the immediate SwiftUI path in
    // both event orders; at worst an ordinary caret update is coalesced for 120 milliseconds.
    defersNextCompletedUpdate = true
    let shouldCommit = hasPendingCompositionEdit
    hasPendingCompositionEdit = false
    return .init(
      defersSelectionPublication: true,
      notifiesUserEdit: shouldCommit,
      schedulesMarkdownSync: shouldCommit
    )
  }
}

/// A local-only MarkEdit host. The complete pinned source stays in `ThirdParty/MarkEdit`; Dayday
/// layers its Live Preview extension through MarkEdit's public extension API instead of forking
/// the editor. Journal text and images never leave the local WebKit process.
struct JournalMarkEditEditor: NSViewRepresentable {
  @Binding var markdown: String
  let placeholder: String
  let editorTheme: DaydayMarkdownEditorTheme
  let imageResources: [JournalAttachmentID: Data]
  let pendingAttachment: JournalAttachment?
  let attachmentRequest: Int
  let action: JournalMarkdownEditorAction?
  let actionRequest: Int
  let snapshotRequest: Int
  let reloadRequest: Int
  let isSourceMode: Bool
  let isReadOnly: Bool
  let isActive: Bool
  let accessibilityLabel: String
  let onStateChange: @MainActor (JournalMarkEditState) -> Void
  let onSelectionChange: @MainActor (JournalMarkEditSelectionState) -> Void
  let onRequestAttachmentRemoval: @MainActor (JournalAttachmentID) -> Void
  let onUserEdit: @MainActor () -> Void
  let onSnapshot: @MainActor (String?, Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> JournalMarkEditHostView {
    let host = JournalMarkEditHostView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.isHidden = !isActive
    host.setAccessibilityLabel(accessibilityLabel)
    context.coordinator.install(in: host)
    return host
  }

  func updateNSView(_ host: JournalMarkEditHostView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updateAccessibilityLabelIfNeeded(in: host)
    context.coordinator.updateActivityIfNeeded(in: host)
    context.coordinator.reloadIfNeeded()
    context.coordinator.updateImagesIfNeeded(imageResources)
    context.coordinator.receiveExternalMarkdownIfNeeded(markdown)
    context.coordinator.updateReadOnlyModeIfNeeded()
    context.coordinator.updateEditorChromeIfNeeded()
    context.coordinator.applyPendingAttachmentIfNeeded()
    context.coordinator.applyActionIfNeeded()
    context.coordinator.publishSnapshotIfRequested()
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: JournalMarkEditEditor
    private let resourceBundle: Bundle
    private weak var webView: WKWebView?
    private var bridge: WebModuleBridge?
    private var attachmentLoader: JournalAttachmentResourceLoader?
    private var isLoaded = false
    private var isInitializingEditor = false
    private var isApplyingExternalValue = false
    private var lastMarkdown: String
    private var lastImageResourceIDs: Set<JournalAttachmentID>
    private var lastAttachmentRequest = 0
    private var lastActionRequest = 0
    private var lastSnapshotRequest = 0
    private var lastReloadRequest = 0
    private var lastReadOnlyMode: Bool
    private var lastIsActive: Bool
    private var lastAccessibilityLabel: String
    private var lastAppliedEditorTheme: DaydayMarkdownEditorTheme?
    private var lastAppliedPlaceholder: String?
    private var inputSynchronization = JournalEditorInputSynchronizationState()
    private var lastPublishedSelection = JournalMarkEditSelectionState()
    private var hasUnsynchronizedEditorChanges = false
    private var hasPendingUserEditNotification = false
    private var syncTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    init(parent: JournalMarkEditEditor, resourceBundle: Bundle = .main) {
      self.parent = parent
      self.resourceBundle = resourceBundle
      self.lastMarkdown = parent.markdown
      self.lastImageResourceIDs = Set(parent.imageResources.keys)
      self.lastReadOnlyMode = parent.isReadOnly
      self.lastIsActive = parent.isActive
      self.lastAccessibilityLabel = parent.accessibilityLabel
    }

    deinit {
      syncTask?.cancel()
      selectionTask?.cancel()
      readinessTask?.cancel()
      snapshotTask?.cancel()
    }

    func install(in host: JournalMarkEditHostView) {
      let core = EditorModuleCore(delegate: self)
      let modules = NativeModules(modules: [
        core,
        EditorModuleTokenizer(),
        EditorModuleAPI(delegate: self),
      ])
      let contentController = WKUserContentController()
      contentController.addScriptMessageHandler(
        EditorMessageHandler(modules: modules),
        contentWorld: .page,
        name: "bridge"
      )
      contentController.add(
        JournalMarkEditMessageHandler(delegate: self),
        contentWorld: .page,
        name: "daydayJournal"
      )

      let configuration = WKWebViewConfiguration.newConfig()
      configuration.userContentController = contentController
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      configuration.websiteDataStore = .nonPersistent()
      configuration.setURLSchemeHandler(
        JournalMarkEditChunkLoader(bundle: resourceBundle),
        forURLScheme: JournalMarkEditChunkLoader.scheme
      )
      let attachmentLoader = JournalAttachmentResourceLoader(resources: parent.imageResources)
      configuration.setURLSchemeHandler(
        attachmentLoader,
        forURLScheme: JournalAttachmentResourceLoader.scheme
      )

      let webView = JournalMarkEditWebView(frame: .zero, configuration: configuration)
      webView.navigationDelegate = self
      webView.setAccessibilityLabel(parent.accessibilityLabel)
      host.embed(webView)
      self.webView = webView
      self.attachmentLoader = attachmentLoader
      bridge = WebModuleBridge(webView: webView)
      loadEditor(in: webView)
    }

    func updateActivityIfNeeded(in host: JournalMarkEditHostView) {
      guard lastIsActive != parent.isActive else { return }
      lastIsActive = parent.isActive
      host.isHidden = !parent.isActive

      guard !parent.isActive, let webView else { return }
      if let firstResponder = webView.window?.firstResponder as? NSView,
        firstResponder === webView || firstResponder.isDescendant(of: webView)
      {
        webView.window?.makeFirstResponder(nil)
      }
      webView.evaluateJavaScript("document.activeElement?.blur?.()")
    }

    func updateAccessibilityLabelIfNeeded(in host: JournalMarkEditHostView) {
      guard lastAccessibilityLabel != parent.accessibilityLabel else { return }
      lastAccessibilityLabel = parent.accessibilityLabel
      host.setAccessibilityLabel(parent.accessibilityLabel)
      webView?.setAccessibilityLabel(parent.accessibilityLabel)
    }

    func updateImagesIfNeeded(_ resources: [JournalAttachmentID: Data]) {
      let imageIDs = Set(resources.keys)
      guard imageIDs != lastImageResourceIDs else { return }
      lastImageResourceIDs = imageIDs
      attachmentLoader?.update(resources: resources)
      webView?.evaluateJavaScript(
        """
        if (typeof window.daydayJournalRefreshPreview === 'function') {
          window.daydayJournalRefreshPreview();
        } else {
          window.editor?.dispatch({});
        }
        """
      )
    }

    func receiveExternalMarkdownIfNeeded(_ markdown: String) {
      guard isLoaded, !isApplyingExternalValue, markdown != lastMarkdown else { return }
      cancelScheduledMarkdownSync()
      hasUnsynchronizedEditorChanges = false
      lastMarkdown = markdown
      bridge?.core.resetEditor(text: markdown)
    }

    func applyPendingAttachmentIfNeeded() {
      guard isLoaded, !parent.isReadOnly,
        lastAttachmentRequest != parent.attachmentRequest,
        let attachment = parent.pendingAttachment,
        case .image = attachment.payload
      else { return }
      lastAttachmentRequest = parent.attachmentRequest
      let source = "![图片](dayday-attachment://\(attachment.id.rawValue.uuidString.lowercased()))"
      bridge?.core.replaceText(text: source, granularity: .selection)
    }

    func applyActionIfNeeded() {
      guard isLoaded,
        lastActionRequest != parent.actionRequest,
        let action = parent.action,
        let bridge
      else { return }
      lastActionRequest = parent.actionRequest
      if parent.isReadOnly {
        if case .sourceMode(let enabled) = action {
          setSourceMode(enabled)
        }
        return
      }
      switch action {
      case .heading(let level): bridge.format.toggleHeading(level: level)
      case .bold: bridge.format.toggleBold()
      case .italic: bridge.format.toggleItalic()
      case .strikethrough: bridge.format.toggleStrikethrough()
      case .bullet: bridge.format.toggleBullet()
      case .ordered: bridge.format.toggleNumbering()
      case .task: bridge.format.toggleTodo()
      case .quote: bridge.format.toggleBlockquote()
      case .inlineCode: bridge.format.toggleInlineCode()
      case .inlineMath: bridge.format.toggleInlineMath()
      case .codeBlock: bridge.format.insertCodeBlock()
      case .mathBlock: bridge.format.insertMathBlock()
      case .horizontalRule: bridge.format.insertHorizontalRule()
      case .link(let title, let url):
        bridge.format.insertHyperLink(title: title, url: url, prefix: nil)
      case .table: bridge.format.insertTable(columnName: "列", itemName: "内容")
      case .insertText(let text): bridge.core.replaceText(text: text, granularity: .selection)
      case .indentLess: bridge.format.performEditCommand(command: .indentLess)
      case .indentMore: bridge.format.performEditCommand(command: .indentMore)
      case .moveLineUp: bridge.format.performEditCommand(command: .moveLineUp)
      case .moveLineDown: bridge.format.performEditCommand(command: .moveLineDown)
      case .copyLineUp: bridge.format.performEditCommand(command: .copyLineUp)
      case .copyLineDown: bridge.format.performEditCommand(command: .copyLineDown)
      case .undo: bridge.history.undo()
      case .redo: bridge.history.redo()
      case .sourceMode(let enabled):
        setSourceMode(enabled)
      }
      webView?.evaluateJavaScript("window.editor?.focus()")
    }

    private func setSourceMode(_ isSourceMode: Bool) {
      webView?.evaluateJavaScript(
        "window.daydayJournalSetLivePreview?.(\(!isSourceMode))"
      )
    }

    func updateReadOnlyModeIfNeeded() {
      guard isLoaded, lastReadOnlyMode != parent.isReadOnly, let bridge else { return }
      lastReadOnlyMode = parent.isReadOnly
      bridge.config.setReadOnlyMode(enabled: parent.isReadOnly)
    }

    func updateEditorChromeIfNeeded(force: Bool = false) {
      guard isLoaded, let webView else { return }
      let themeChanged = lastAppliedEditorTheme != parent.editorTheme
      let placeholderChanged = lastAppliedPlaceholder != parent.placeholder
      guard force || themeChanged || placeholderChanged else { return }
      guard let theme = Self.javaScriptLiteral(parent.editorTheme),
        let placeholder = Self.javaScriptLiteral(parent.placeholder)
      else { return }
      webView.evaluateJavaScript(
        "window.daydayJournalSetTheme?.(\(theme));"
          + "window.daydayJournalSetPlaceholder?.(\(placeholder));"
      )
      lastAppliedEditorTheme = parent.editorTheme
      lastAppliedPlaceholder = parent.placeholder
    }

    func publishSnapshotIfRequested() {
      let request = parent.snapshotRequest
      guard isLoaded, request != lastSnapshotRequest else { return }
      lastSnapshotRequest = request
      snapshotTask?.cancel()
      snapshotTask = Task { [weak self] in
        await self?.publishSnapshot(request: request)
      }
    }

    private func publishSnapshot(request: Int) async {
      guard let bridge, let source = try? await bridge.core.getEditorText() else {
        snapshotTask = nil
        parent.onSnapshot(nil, request)
        return
      }
      guard !Task.isCancelled, parent.snapshotRequest == request else { return }
      cancelScheduledMarkdownSync()
      hasUnsynchronizedEditorChanges = false
      isApplyingExternalValue = true
      lastMarkdown = source
      parent.markdown = source
      isApplyingExternalValue = false
      if hasPendingUserEditNotification {
        hasPendingUserEditNotification = false
        parent.onUserEdit()
      }
      parent.onSnapshot(source, request)
      snapshotTask = nil
    }

    private func loadEditor(in webView: WKWebView) {
      let html: String
      do {
        html = try JournalMarkEditResources.html(
          configuration: editorConfiguration(text: lastMarkdown),
          bundle: resourceBundle
        )
        guard
          JournalMarkEditResources.text(for: "dayday-live-preview.js", bundle: resourceBundle)
            != nil
        else {
          publishEditorState(.failed)
          return
        }
      } catch {
        publishEditorState(.failed)
        return
      }
      publishEditorState(.loading)
      isLoaded = false
      isInitializingEditor = false
      lastAppliedEditorTheme = nil
      lastAppliedPlaceholder = nil
      readinessTask?.cancel()
      webView.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))
      readinessTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(5))
        guard let self, !Task.isCancelled, !self.isLoaded else { return }
        self.parent.onStateChange(.failed)
      }
    }

    private func publishEditorState(_ state: JournalMarkEditState) {
      // NSView creation runs during a SwiftUI update; publish after that update finishes.
      DispatchQueue.main.async { [weak self] in
        self?.parent.onStateChange(state)
      }
    }

    func reloadIfNeeded() {
      guard lastReloadRequest != parent.reloadRequest, let webView else { return }
      lastReloadRequest = parent.reloadRequest
      loadEditor(in: webView)
    }

    func initializeEditorIfNeeded() {
      guard !isLoaded, !isInitializingEditor, webView != nil, bridge != nil else { return }
      isInitializingEditor = true
      installLivePreview(attempt: 0)
    }

    private func installLivePreview(attempt: Int) {
      guard let webView,
        let script = JournalMarkEditResources.text(
          for: "dayday-live-preview.js", bundle: resourceBundle)
      else {
        failInitialization()
        return
      }
      webView.evaluateJavaScript(script) { [weak self] _, error in
        Task { @MainActor in
          guard let self else { return }
          if error != nil {
            guard attempt < 30 else {
              self.failInitialization()
              return
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, !self.isLoaded else { return }
            self.installLivePreview(attempt: attempt + 1)
            return
          }
          self.resetEditorAfterInstallingLivePreview()
        }
      }
    }

    private func resetEditorAfterInstallingLivePreview() {
      guard let bridge else {
        failInitialization()
        return
      }
      bridge.core.resetEditor(text: lastMarkdown) { [weak self] result in
        guard let self else { return }
        self.isInitializingEditor = false
        guard case .success = result else {
          self.failInitialization()
          return
        }
        self.isLoaded = true
        self.readinessTask?.cancel()
        self.lastReadOnlyMode = self.parent.isReadOnly
        bridge.config.setReadOnlyMode(enabled: self.parent.isReadOnly)
        self.setSourceMode(self.parent.isSourceMode)
        self.parent.onStateChange(.ready)
        self.updateEditorChromeIfNeeded(force: true)
        if self.parent.isActive {
          self.webView?.window?.makeFirstResponder(self.webView)
          self.webView?.evaluateJavaScript("window.editor?.focus()")
        }
        self.applyPendingAttachmentIfNeeded()
        self.applyActionIfNeeded()
        self.publishSnapshotIfRequested()
      }
    }

    private func failInitialization() {
      isInitializingEditor = false
      isLoaded = false
      parent.onStateChange(.failed)
    }

    private func editorConfiguration(text: String) -> EditorConfig {
      EditorConfig(
        text: text,
        theme: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? "github-dark" : "github-light",
        fontFace: .init(family: "-apple-system", weight: nil, style: nil),
        fontSize: 18,
        showLineNumbers: false,
        showActiveLineIndicator: false,
        invisiblesBehavior: .never,
        readOnlyMode: parent.isReadOnly,
        typewriterMode: false,
        focusMode: false,
        lineWrapping: true,
        lineHeight: 1.62,
        suggestWhileTyping: false,
        defaultLineBreak: "\n",
        tabKeyBehavior: JournalMarkEditConfiguration.tabKeyBehavior,
        indentUnit: JournalMarkEditConfiguration.indentUnit,
        localizable: nil,
        autoCharacterPairs: true,
        indentBehavior: .paragraph,
        headerFontSizeDiffs: [12, 8, 5, 3, 1, 0],
        visibleWhitespaceCharacter: nil,
        visibleLineBreakCharacter: nil,
        searchNormalizers: nil
      )
    }

    private static func javaScriptLiteral<T: Encodable>(_ value: T) -> String? {
      guard let data = try? JSONEncoder().encode(value) else { return nil }
      return String(data: data, encoding: .utf8)
    }

    private func scheduleMarkdownSync() {
      cancelScheduledMarkdownSync()
      hasUnsynchronizedEditorChanges = true
      syncTask = Task { [weak self] in
        do {
          // Keep the exact editor snapshot and autosave semantics, but do not cross WebKit ->
          // Swift while the user is moving between short Pinyin composition sessions.
          try await Task.sleep(for: .milliseconds(1500))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await self?.synchronizeMarkdown()
        guard !Task.isCancelled else { return }
        self?.syncTask = nil
      }
    }

    private func cancelScheduledMarkdownSync() {
      syncTask?.cancel()
      syncTask = nil
    }

    private func synchronizeMarkdown() async {
      guard !inputSynchronization.isComposing, let bridge else { return }
      guard
        let source = try? await bridge.core.getEditorText(),
        !Task.isCancelled
      else { return }
      hasUnsynchronizedEditorChanges = false
      guard source != lastMarkdown else {
        hasPendingUserEditNotification = false
        return
      }
      isApplyingExternalValue = true
      lastMarkdown = source
      parent.markdown = source
      isApplyingExternalValue = false
      if hasPendingUserEditNotification {
        hasPendingUserEditNotification = false
        parent.onUserEdit()
      }
    }

    private func publishSelection(_ info: LineColumnInfo) {
      publishSelection(
        .init(
          selectedText: info.selectionText,
          attachmentID: Self.attachmentID(in: info.selectionText)
        ))
    }

    private func publishSelection(_ selection: JournalMarkEditSelectionState) {
      guard selection != lastPublishedSelection else { return }
      lastPublishedSelection = selection
      parent.onSelectionChange(selection)
    }

    private func scheduleSelectionPublication(_ info: LineColumnInfo) {
      selectionTask?.cancel()
      let selection = JournalMarkEditSelectionState(
        selectedText: info.selectionText,
        attachmentID: Self.attachmentID(in: info.selectionText)
      )
      selectionTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(120))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        self?.publishSelection(selection)
        self?.selectionTask = nil
      }
    }

    private func applyInputDecision(
      _ decision: JournalEditorInputUpdateDecision,
      selection: LineColumnInfo
    ) {
      if decision.cancelsMarkdownSync {
        cancelScheduledMarkdownSync()
        selectionTask?.cancel()
        selectionTask = nil
      }
      if decision.publishesSelection {
        selectionTask?.cancel()
        selectionTask = nil
        publishSelection(selection)
      }
      if decision.defersSelectionPublication {
        scheduleSelectionPublication(selection)
      }
      if decision.notifiesUserEdit {
        // Automatic location capture and other surrounding UI work wait for the same quiet
        // checkpoint as persistence instead of starting while the next phrase is being composed.
        hasPendingUserEditNotification = true
      }
      if decision.schedulesMarkdownSync {
        scheduleMarkdownSync()
      }
    }

    private static func attachmentID(in markdown: String) -> JournalAttachmentID? {
      guard
        let range = markdown.range(
          of: #"dayday-attachment://([0-9A-Fa-f-]{36})"#,
          options: .regularExpression
        )
      else { return nil }
      let value = String(markdown[range]).replacingOccurrences(of: "dayday-attachment://", with: "")
      guard let uuid = UUID(uuidString: value) else { return nil }
      return JournalAttachmentID(rawValue: uuid)
    }
  }
}

@MainActor
extension JournalMarkEditEditor.Coordinator: EditorModuleCoreDelegate {
  func editorCoreWindowDidLoad(_ sender: EditorModuleCore) {
    initializeEditorIfNeeded()
  }

  func editorCoreEditorDidBecomeIdle(_ sender: EditorModuleCore) {
    guard !inputSynchronization.isComposing,
      hasUnsynchronizedEditorChanges,
      syncTask == nil
    else { return }
    Task { await synchronizeMarkdown() }
  }

  func editorCoreBackgroundColorDidChange(_ sender: EditorModuleCore, color: UInt32, alpha: Double)
  {}
  func editorCoreViewportScaleDidChange(_ sender: EditorModuleCore) {}

  func editorCoreViewDidUpdate(
    _ sender: EditorModuleCore,
    contentEdited: Bool,
    compositionEnded: Bool,
    isDirty: Bool,
    selectedLineColumn: LineColumnInfo
  ) {
    let decision = inputSynchronization.viewDidUpdate(
      contentEdited: contentEdited,
      compositionEnded: compositionEnded
    )
    applyInputDecision(decision, selection: selectedLineColumn)
  }

  func editorCoreContentHeightDidChange(_ sender: EditorModuleCore, bottomPanelHeight: Double) {}
  func editorCoreContentOffsetDidChange(_ sender: EditorModuleCore) {}
  func editorCoreCompositionEnded(_ sender: EditorModuleCore, selectedLineColumn: LineColumnInfo) {
    let decision = inputSynchronization.compositionDidEnd()
    applyInputDecision(decision, selection: selectedLineColumn)
  }

  func editorCoreLinkClicked(_ sender: EditorModuleCore, link: String) {
    guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    NSWorkspace.shared.open(url)
  }

  func editorCoreLightWarning(_ sender: EditorModuleCore) {
    NSSound.beep()
  }
}

@MainActor
extension JournalMarkEditEditor.Coordinator: EditorModuleAPIDelegate {
  func editorAPIGetFileURL(_ sender: EditorModuleAPI) -> URL? { nil }
  func editorAPI(_ sender: EditorModuleAPI, addMainMenuItems items: [(String, WebMenuItem)]) {}
  func editorAPI(
    _ sender: EditorModuleAPI, showContextMenu items: [WebMenuItem], location: WebPoint
  ) {}
  func editorAPI(
    _ sender: EditorModuleAPI,
    alertWith title: String?,
    message: String?,
    buttons: [String]?
  ) -> Int { 0 }
  func editorAPI(
    _ sender: EditorModuleAPI,
    showTextBox title: String?,
    placeholder: String?,
    defaultValue: String?
  ) -> String? { nil }
  func editorAPI(_ sender: EditorModuleAPI, showSavePanel data: Data, fileName: String?) -> Bool {
    false
  }
}

@MainActor
extension JournalMarkEditEditor.Coordinator: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.initializeEditorIfNeeded()
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failInitialization()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    failInitialization()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failInitialization()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let isEditorDocument = url.scheme == "http" && url.host == "localhost"
    decisionHandler(isEditorDocument ? .allow : .cancel)
  }
}

@MainActor
extension JournalMarkEditEditor.Coordinator: JournalMarkEditMessageDelegate {
  func journalMarkEditMessage(
    action: String,
    attachmentID: JournalAttachmentID?
  ) {
    switch action {
    case "selectAttachment":
      publishSelection(.init(attachmentID: attachmentID))
    case "clearAttachmentSelection":
      publishSelection(.init())
    case "removeAttachment":
      guard let attachmentID else { return }
      parent.onRequestAttachmentRemoval(attachmentID)
    default:
      break
    }
  }
}

final class JournalMarkEditWebView: WKWebView {
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }
}

final class JournalMarkEditHostView: NSView {
  override var isFlipped: Bool { true }

  func embed(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      view.topAnchor.constraint(equalTo: topAnchor),
      view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

private final class JournalMarkEditChunkLoader: NSObject, WKURLSchemeHandler {
  static let scheme = "chunk-loader"
  private let bundle: Bundle

  init(bundle: Bundle = .main) {
    self.bundle = bundle
    super.init()
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url,
      url.host == "chunks",
      let resourceURL = JournalMarkEditResources.url(
        for: "chunks/\(url.lastPathComponent)", bundle: bundle),
      let data = try? Data(contentsOf: resourceURL)
    else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    let mimeType =
      switch url.pathExtension {
      case "js": "text/javascript"
      case "css": "text/css"
      case "woff2": "font/woff2"
      default: "application/octet-stream"
      }
    let response =
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
          "Access-Control-Allow-Origin": "*",
          "Cache-Control": "no-store",
          "Content-Type": mimeType,
        ]
      )
      ?? URLResponse(
        url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class JournalAttachmentResourceLoader: NSObject, WKURLSchemeHandler,
  @unchecked Sendable
{
  static let scheme = "dayday-attachment"

  private let lock = NSLock()
  private var imageData: [UUID: Data] = [:]

  init(resources: [JournalAttachmentID: Data]) {
    super.init()
    update(resources: resources)
  }

  func update(resources: [JournalAttachmentID: Data]) {
    let encoded = resources.reduce(into: [UUID: Data]()) { result, item in
      result[item.key.rawValue] = item.value
    }
    lock.withLock { imageData = encoded }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url,
      let host = url.host,
      let uuid = UUID(uuidString: host),
      let data = lock.withLock({ imageData[uuid] })
    else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    let response = URLResponse(
      url: url,
      mimeType: "image/png",
      expectedContentLength: data.count,
      textEncodingName: nil
    )
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private protocol JournalMarkEditMessageDelegate: AnyObject {
  func journalMarkEditMessage(
    action: String,
    attachmentID: JournalAttachmentID?
  )
}

private final class JournalMarkEditMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var delegate: (any JournalMarkEditMessageDelegate)?

  init(delegate: any JournalMarkEditMessageDelegate) {
    self.delegate = delegate
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any],
      let action = body["action"] as? String
    else { return }
    let attachmentID = (body["id"] as? String)
      .flatMap(UUID.init(uuidString:))
      .map { JournalAttachmentID(rawValue: $0) }
    Task { @MainActor [weak delegate] in
      delegate?.journalMarkEditMessage(
        action: action,
        attachmentID: attachmentID
      )
    }
  }
}

enum JournalMarkEditResources {
  enum LoadingError: Error, Equatable {
    case missingTemplate
  }

  static func html(configuration: EditorConfig, bundle: Bundle = .main) throws -> String {
    guard let templateURL = url(for: "index.html", bundle: bundle) else {
      throw LoadingError.missingTemplate
    }
    let template = try String(contentsOf: templateURL, encoding: .utf8)
    let configurationJSON = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
    return
      template
      .replacingOccurrences(of: "/chunk-loader/", with: "chunk-loader://")
      .replacingOccurrences(of: "\"{{EDITOR_CONFIG}}\"", with: configurationJSON)
      .replacingOccurrences(of: "\"{{USER_SETTINGS}}\"", with: "{}")
  }

  static func url(for name: String, bundle: Bundle = .main) -> URL? {
    let path = name.hasPrefix("/") ? String(name.dropFirst()) : name
    let pathURL = URL(fileURLWithPath: path)
    let fileName = pathURL.deletingPathExtension().lastPathComponent
    let fileExtension = pathURL.pathExtension
    return bundle.url(forResource: "MarkEdit/\(path)", withExtension: nil)
      ?? bundle.url(
        forResource: fileName,
        withExtension: fileExtension.isEmpty ? nil : fileExtension
      )
  }

  static func text(for name: String, bundle: Bundle = .main) -> String? {
    guard let url = url(for: name, bundle: bundle), let data = try? Data(contentsOf: url) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}
