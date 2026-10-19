import AppKit
import DaydayCore
import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum JournalReviewLayoutPolicy {
  static let minimumWidth: CGFloat = 280
  static let idealWidth: CGFloat = 320
  static let maximumWidth: CGFloat = 380
}

struct DaydayWritingReviewPalette: Equatable {
  let action: DaydayRGBA
  let selectionFill: DaydayRGBA
  let selectionBorder: DaydayRGBA

  init(theme: DaydayTheme) {
    action = theme.primitive(.action)
    selectionFill = theme.primitive(.selectionFill)
    selectionBorder = theme.primitive(.selectionBorder)
  }
}

struct JournalView: View {
  @ObservedObject var journal: JournalEntryModel
  @ObservedObject var journalAI: JournalAIAssistantModel
  @ObservedObject var history: JournalHistoryModel
  @ObservedObject var journalFragments: JournalFragmentModel
  @ObservedObject var attachments: JournalAttachmentModel
  @ObservedObject var locations: JournalLocationModel
  @ObservedObject var weather: WeatherRuntime
  let isActive: Bool

  @State private var isImageImporterPresented = false
  @State private var mapSnapshot: JournalLocationSnapshot?
  @State private var editorAction: JournalMarkdownEditorAction?
  @State private var editorActionRequest = 0
  @State private var editorSelection = JournalMarkEditSelectionState()
  @State private var isSourceMode = false
  @State private var didRequestAutomaticLocationCapture = false
  @State private var pendingAttachment: JournalAttachment?
  @State private var attachmentRequest = 0
  @State private var isReviewInspectorPresented = true
  @State private var isLinkEditorPresented = false
  @State private var linkLabel = ""
  @State private var linkDestination = ""
  @State private var attachmentPendingRemoval: JournalAttachment?
  @State private var exportFeedback: String?
  @State private var editorSnapshotRequest = 0
  @State private var pendingAIOperation: JournalDerivedOperation?
  @State private var pendingAICustomInstruction: String?
  @State private var isCustomAIPromptPresented = false
  @State private var customAIPrompt = ""

  var body: some View {
    VStack(spacing: 0) {
      journalWorkspace
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .toolbar {
      if DaydayWritingToolbarPresentation.isVisible(isActive: isActive) {
        ToolbarItemGroup(placement: .automatic) {
          formatMenu
          journalAIMenu
          deleteSelectedImageButton
            .daydayWritingToolbarIcon()
          insertImageButton
            .daydayWritingToolbarIcon()
        }
        ToolbarItemGroup(placement: .primaryAction) {
          sourceModeButton
            .daydayWritingToolbarIcon()
          exportButton
            .daydayWritingToolbarIcon()
          journalReviewButton
            .daydayWritingToolbarIcon()
        }
      }
    }
    .task { await history.loadIfNeeded() }
    .inspector(isPresented: activeReviewInspectorBinding) {
      journalReviewSidebar
        .inspectorColumnWidth(
          min: JournalReviewLayoutPolicy.minimumWidth,
          ideal: JournalReviewLayoutPolicy.idealWidth,
          max: JournalReviewLayoutPolicy.maximumWidth
        )
    }
    .fileImporter(
      isPresented: $isImageImporterPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      Task {
        if let attachment = await attachments.importImage(from: url) {
          pendingAttachment = attachment
          attachmentRequest += 1
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { mapSnapshot != nil },
        set: { if !$0 { mapSnapshot = nil } }
      )
    ) {
      if let mapSnapshot {
        JournalLocationMapSheet(
          snapshot: mapSnapshot,
          placeName: locations.placeName(for: mapSnapshot)
        )
      }
    }
    .sheet(isPresented: $isLinkEditorPresented) {
      DaydayMarkdownLinkEditor(
        label: $linkLabel,
        destination: $linkDestination,
        insert: insertLink
      )
    }
    .sheet(isPresented: $isCustomAIPromptPresented) {
      JournalCustomAIPromptSheet(
        instruction: $customAIPrompt,
        submit: {
          let instruction = customAIPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !instruction.isEmpty else { return }
          isCustomAIPromptPresented = false
          requestAI(.rewrite, customInstruction: instruction)
        }
      )
    }
    .sheet(
      isPresented: Binding(
        get: { journalAI.preview != nil },
        set: { if !$0 { journalAI.preview = nil } }
      )
    ) {
      if let version = journalAI.preview {
        JournalAIPreviewSheet(
          version: version,
          isGenerating: journalAI.isGenerating,
          status: journalAI.status,
          accept: journalAI.acceptPreview,
          regenerate: journalAI.regenerate,
          close: { journalAI.preview = nil }
        )
      }
    }
    .confirmationDialog(
      "删除这张图片？",
      isPresented: Binding(
        get: { attachmentPendingRemoval != nil },
        set: { if !$0 { attachmentPendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除图片", role: .destructive) {
        guard let attachment = attachmentPendingRemoval else { return }
        attachmentPendingRemoval = nil
        Task { await attachments.remove(attachment) }
      }
      Button("取消", role: .cancel) { attachmentPendingRemoval = nil }
    } message: {
      Text("图片会从正文与 Dayday 的本机私有附件库移除。")
    }
    .onChange(of: isActive, initial: true) {
      if !isActive {
        didRequestAutomaticLocationCapture = false
        return
      }
      Task {
        await locations.reloadForSelectedDay()
        requestAutomaticLocationCaptureIfNeeded()
      }
    }
    .onChange(of: journal.selectedDay?.id, initial: true) {
      guard let day = journal.selectedDay else { return }
      journalAI.selectedDayDidChange()
      didRequestAutomaticLocationCapture = false
      Task {
        async let fragmentsReload: Void = journalFragments.refresh(day: day)
        async let attachmentsReload: Void = attachments.reloadForSelectedDay()
        async let locationsReload: Void = locations.reloadForSelectedDay()
        _ = await (fragmentsReload, attachmentsReload, locationsReload)
        await journalAI.reload()
        requestAutomaticLocationCaptureIfNeeded()
      }
    }
  }

  private var journalWorkspace: some View {
    writingSurface
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var journalReviewSidebar: some View {
    JournalReviewSidebar(
      history: history,
      journal: journal,
      selectDate: { date in
        Task { await journal.selectCalendarDay(date) }
      }
    )
  }

  private var formatMenu: some View {
    DaydayMarkdownFormatMenu(
      disabled: false,
      iconOnly: true,
      requestAction: requestEditorAction,
      presentLinkEditor: presentLinkEditor
    )
  }

  private var journalAIMenu: some View {
    Menu {
      Button("整理结构", systemImage: "text.alignleft") { requestAI(.organize) }
      Button("改善表达", systemImage: "wand.and.stars") { requestAI(.rewrite) }
      Button("继续写下去", systemImage: "text.append") { requestAI(.continueWriting) }
      Button("校对文字", systemImage: "checkmark.circle") { requestAI(.proofread) }
      Divider()
      Button("自定义指令…", systemImage: "slider.horizontal.3") {
        isCustomAIPromptPresented = true
      }
      if !journalAI.versions.isEmpty {
        Divider()
        Menu("最近生成") {
          ForEach(journalAI.versions.prefix(8), id: \.id) { version in
            Button {
              journalAI.present(version)
            } label: {
              Text("\(version.operation.journalDisplayName) · \(version.createdAt.formatted(date: .omitted, time: .shortened))")
            }
          }
        }
      }
    } label: {
      Label("AI 写作", systemImage: DaydayWritingToolbarSymbol.journalAI)
        .labelStyle(.titleAndIcon)
    }
    .disabled(!journal.hasContent || journalAI.isGenerating || journal.isSwitchingDay)
    .help(journalAI.status)
  }

  private var insertImageButton: some View {
    Button("插入图片", systemImage: DaydayWritingToolbarSymbol.insertImage) {
      isImageImporterPresented = true
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])
    .help("在光标处插入图片")
  }

  private var deleteSelectedImageButton: some View {
    Button("删除所选图片", systemImage: DaydayWritingToolbarSymbol.deleteImage) {
      guard let attachmentID = editorSelection.attachmentID else { return }
      requestAttachmentRemoval(attachmentID)
    }
    .disabled(editorSelection.attachmentID == nil)
    .foregroundStyle(editorSelection.attachmentID == nil ? Color.secondary : Color.red)
    .help(
      editorSelection.attachmentID == nil
        ? "先在正文中选择一张图片" : "删除正文中选中的图片"
    )
  }

  private var journalReviewButton: some View {
    Button(
      isReviewInspectorPresented ? "隐藏回顾" : "显示回顾",
      systemImage: DaydayWritingToolbarSymbol.review
    ) {
      toggleReviewInspector()
    }
    .keyboardShortcut("h", modifiers: [.command, .shift])
    .help(isReviewInspectorPresented ? "隐藏日记回顾" : "从右侧显示日记回顾")
    .foregroundStyle(isReviewInspectorPresented ? Color.accentColor : Color.primary)
    .accessibilityValue(isReviewInspectorPresented ? "已显示" : "已隐藏")
    .accessibilityIdentifier("journal.review-inspector.toggle")
  }

  private func toggleReviewInspector() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isReviewInspectorPresented.toggle()
    }
  }

  private var sourceModeButton: some View {
    Button(
      isSourceMode ? "实时预览" : "Markdown 源码",
      systemImage: isSourceMode
        ? DaydayWritingToolbarSymbol.preview : DaydayWritingToolbarSymbol.source
    ) {
      toggleSourceMode()
    }
    .help(isSourceMode ? "返回实时预览" : "查看 Markdown 源码")
    .foregroundStyle(isSourceMode ? Color.accentColor : Color.primary)
    .accessibilityValue(isSourceMode ? "源码模式" : "实时预览模式")
  }

  private var exportButton: some View {
    Button("导出 Markdown", systemImage: DaydayWritingToolbarSymbol.export) {
      Task { await exportCurrentJournal() }
    }
    .disabled(!journal.hasContent)
    .help("导出当前日记及其图片")
  }

  private var activeReviewInspectorBinding: Binding<Bool> {
    Binding(
      get: { isActive && isReviewInspectorPresented },
      // SwiftUI writes `false` when a retained page becomes inactive. The toolbar button owns the
      // user's preference so this transient unmount must not erase it before the page is revisited.
      set: { _ in }
    )
  }

  @ViewBuilder
  private var writingSurface: some View {
    let status = exportFeedback ?? journal.status
    let isError = status.contains("失败") || status.contains("无法") || status.contains("未连接")
    let selectedTitle =
      journal.selectedDay.map(JournalDateFormatting.dayTitle)
      ?? JournalDateFormatting.dayTitle(Date.now)
    DaydayMarkdownWritingSurface(
      markdown: Binding(
        get: { journal.body },
        set: { journal.acceptEditorSnapshot($0) }
      ),
      title: selectedTitle,
      placeholder: journal.isSelectedDayToday ? "从此刻开始写下今天……" : "为这一天补写日记……",
      contentAccessibilityLabel:
        "\(selectedTitle)的日记正文，实时 Markdown 预览，支持图片和 macOS 系统听写",
      status: status,
      statusAccessibilityLabel: "日记保存状态",
      statusSystemImage: isError ? "exclamationmark.circle" : "checkmark.circle",
      statusColor: isError ? .orange : .secondary,
      imageResources: attachments.imageResources,
      pendingAttachment: pendingAttachment,
      attachmentRequest: attachmentRequest,
      action: editorAction,
      actionRequest: editorActionRequest,
      snapshotRequest: editorSnapshotRequest,
      isSourceMode: isSourceMode,
      isReadOnly: journal.isSwitchingDay,
      isActive: isActive,
      onSelectionChange: { editorSelection = $0 },
      onRequestAttachmentRemoval: requestAttachmentRemoval,
      onUserEdit: {},
      onSnapshot: { snapshot, request in
        guard request == editorSnapshotRequest, let operation = pendingAIOperation else { return }
        pendingAIOperation = nil
        if let snapshot { journal.acceptEditorSnapshot(snapshot) }
        journalAI.generate(
          operation: operation,
          customInstruction: pendingAICustomInstruction
        )
        pendingAICustomInstruction = nil
      }
    ) {
      journalContextLine
    }
  }

  @ViewBuilder
  private var journalContextLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        journalWeatherLabel
        journalLocationButton
      }
      VStack(alignment: .leading, spacing: 6) {
        journalWeatherLabel
        journalLocationButton
      }
    }
  }

  @ViewBuilder
  private var journalWeatherLabel: some View {
    if journal.isSelectedDayToday, let snapshot = weather.snapshot {
      Label(
        "\(snapshot.district) · \(Int(snapshot.temperatureCelsius.rounded()))℃",
        systemImage: "cloud.sun"
      )
    }
  }

  @ViewBuilder
  private var journalLocationButton: some View {
    if let snapshot = locations.snapshots.last,
      snapshot.dayID == journal.selectedDay?.id
    {
      Button {
        mapSnapshot = snapshot
      } label: {
        Label(locations.placeName(for: snapshot) ?? "已记录位置", systemImage: "location")
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .buttonStyle(.plain)
      .help("在地图中查看")
    }
  }

  private func requestEditorAction(_ action: JournalMarkdownEditorAction) {
    editorAction = action
    editorActionRequest += 1
  }

  private func requestAI(
    _ operation: JournalDerivedOperation,
    customInstruction: String? = nil
  ) {
    pendingAIOperation = operation
    pendingAICustomInstruction = customInstruction
    editorSnapshotRequest &+= 1
  }

  private func toggleSourceMode() {
    isSourceMode.toggle()
    requestEditorAction(.sourceMode(isSourceMode))
  }

  private func requestAutomaticLocationCaptureIfNeeded() {
    guard isActive, journal.selectedDay != nil, journal.isSelectedDayToday,
      !didRequestAutomaticLocationCapture
    else { return }
    didRequestAutomaticLocationCapture = true
    locations.captureAutomaticallyIfNeeded()
  }

  private func presentLinkEditor() {
    linkLabel = editorSelection.selectedText
    linkDestination = ""
    isLinkEditorPresented = true
  }

  private func insertLink() -> Bool {
    let rawDestination = linkDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawDestination.isEmpty else { return false }
    let normalized = rawDestination.contains("://") ? rawDestination : "https://\(rawDestination)"
    guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased(),
      (scheme == "http" || scheme == "https"),
      let host = url.host, !host.isEmpty
    else { return false }
    let label = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    requestEditorAction(.link(title: label.isEmpty ? normalized : label, url: url.absoluteString))
    return true
  }

  private func requestAttachmentRemoval(_ id: JournalAttachmentID) {
    attachmentPendingRemoval = attachments.attachments.first { $0.id == id }
  }

  private func exportCurrentJournal() async {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.canCreateDirectories = true
    let exportDate = journal.selectedDay?.boundary.startsAt ?? .now
    panel.nameFieldStringValue = "日记-\(exportDate.formatted(.dateTime.year().month().day())).md"
    guard await panel.begin() == .OK, let markdownURL = panel.url else { return }

    do {
      let resourceDirectory = markdownURL
        .deletingPathExtension()
        .appendingPathExtension("resources")
      let resourcePaths = try await attachments.copyImageResources(to: resourceDirectory)
      let exported = JournalMarkdownExport.document(
        from: journal.body,
        resourcePaths: resourcePaths,
        resourceDirectoryName: resourceDirectory.lastPathComponent
      )
      try Data(exported.utf8).write(to: markdownURL, options: .atomic)
      exportFeedback = "已导出 Markdown 与本地图片资源"
    } catch {
      exportFeedback = "导出失败；本机日记未受影响"
    }
  }

}

private struct JournalCustomAIPromptSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var instruction: String
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("自定义 AI 指令").font(.title2.weight(.semibold))
      Text("AI 会基于完整日记生成一个独立版本，采纳前不会修改正文。")
        .foregroundStyle(.secondary)
      TextEditor(text: $instruction)
        .font(.body)
        .frame(minHeight: 120)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("生成", action: submit)
          .buttonStyle(.borderedProminent)
          .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct JournalAIPreviewSheet: View {
  let version: JournalDerivedVersion
  let isGenerating: Bool
  let status: String
  private let renderedBody: AttributedString
  let accept: () -> Void
  let regenerate: () -> Void
  let close: () -> Void

  init(
    version: JournalDerivedVersion,
    isGenerating: Bool,
    status: String,
    accept: @escaping () -> Void,
    regenerate: @escaping () -> Void,
    close: @escaping () -> Void
  ) {
    self.version = version
    self.isGenerating = isGenerating
    self.status = status
    self.renderedBody =
      (try? AttributedString(markdown: version.body)) ?? AttributedString(version.body)
    self.accept = accept
    self.regenerate = regenerate
    self.close = close
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("AI \(version.operation.journalDisplayName)版本")
            .font(.title2.weight(.semibold))
          Text("\(version.modelProvenance.model) · \(status)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close)
      }
      .padding(20)
      Divider()
      ScrollView {
        Text(renderedBody)
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(28)
      }
      Divider()
      HStack {
        Button("重新生成", systemImage: "arrow.clockwise", action: regenerate)
          .disabled(isGenerating)
        Spacer()
        Button("采纳到正文", systemImage: "checkmark") {
          accept()
          close()
        }
          .buttonStyle(.borderedProminent)
      }
      .padding(16)
    }
    .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 680)
  }
}

enum JournalMarkdownExport {
  private static let attachmentReference = try! NSRegularExpression(
    pattern: #"!\[((?:\\.|[^\]])*)\]\(dayday-attachment://([0-9A-Fa-f-]{36})\)"#
  )

  static func document(
    from markdown: String,
    resourcePaths: [JournalAttachmentID: String],
    resourceDirectoryName: String
  ) -> String {
    let source = markdown as NSString
    let range = NSRange(location: 0, length: source.length)
    let matches = attachmentReference.matches(in: markdown, range: range)
    var result = markdown
    for match in matches.reversed() {
      let rawID = source.substring(with: match.range(at: 2))
      guard let uuid = UUID(uuidString: rawID),
        let path = resourcePaths[JournalAttachmentID(rawValue: uuid)]
      else { continue }
      let altText = source.substring(with: match.range(at: 1))
      let replacement = "![\(altText)](\(resourceDirectoryName)/\(path))"
      let swiftRange = Range(match.range, in: result)!
      result.replaceSubrange(swiftRange, with: replacement)
    }
    return result
  }
}

private enum JournalBlockStyle: String, Equatable {
  case normal
  case heading
  case bullet
  case ordered
  case quote

  var title: String {
    switch self {
    case .normal: "正文"
    case .heading: "标题"
    case .bullet: "项目列表"
    case .ordered: "编号列表"
    case .quote: "引用"
    }
  }

  var systemImage: String {
    switch self {
    case .normal: "text.alignleft"
    case .heading: "textformat.size.larger"
    case .bullet: "list.bullet"
    case .ordered: "list.number"
    case .quote: "text.quote"
    }
  }
}

private struct JournalEditorSelectionState: Equatable {
  var style: JournalBlockStyle = .normal
  var selectedText = ""
  var attachmentID: JournalAttachmentID?
}

private enum JournalEditorCommand {
  case style(JournalBlockStyle)
  case insertLink(label: String, destination: URL)
  case insertText(String)
}

/// A single native rich-text canvas: formatting and images are rendered in
/// place while the private model remains portable Markdown.
private struct JournalRichTextEditor: NSViewRepresentable {
  @Binding var markdown: String
  let images: [JournalAttachmentID: NSImage]
  let pendingAttachment: JournalAttachment?
  let attachmentRequest: Int
  let command: JournalEditorCommand?
  let commandRequest: Int
  let onSelectionChange: (JournalEditorSelectionState) -> Void
  let onRequestAttachmentRemoval: (JournalAttachmentID) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isRichText = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.font = .systemFont(ofSize: 18)
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isContinuousSpellCheckingEnabled = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 0, height: 6)
    textView.setAccessibilityLabel("日记正文，所见即所得")
    textView.textStorage?.setAttributedString(JournalRichTextCodec.render(markdown, images: images))
    context.coordinator.lastMarkdown = markdown
    context.coordinator.lastImageIDs = Set(images.keys)
    scrollView.documentView = textView
    DispatchQueue.main.async {
      guard textView.window != nil else { return }
      textView.window?.makeFirstResponder(textView)
      context.coordinator.publishSelection(in: textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    let imageIDs = Set(images.keys)
    if !context.coordinator.isEditing,
      markdown != context.coordinator.lastMarkdown || imageIDs != context.coordinator.lastImageIDs {
      context.coordinator.replaceDocument(in: textView, markdown: markdown)
      context.coordinator.lastImageIDs = imageIDs
    }
    if context.coordinator.lastAttachmentRequest != attachmentRequest,
      let pendingAttachment,
      case .image(let image) = pendingAttachment.payload {
      context.coordinator.lastAttachmentRequest = attachmentRequest
      context.coordinator.insertImage(image, id: pendingAttachment.id, in: textView)
    }
    if context.coordinator.lastCommandRequest != commandRequest, let command {
      context.coordinator.lastCommandRequest = commandRequest
      context.coordinator.apply(command, in: textView)
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: JournalRichTextEditor
    var isEditing = false
    var lastMarkdown = ""
    var lastImageIDs: Set<JournalAttachmentID> = []
    var lastAttachmentRequest = 0
    var lastCommandRequest = 0

    init(parent: JournalRichTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !isEditing, let textView = notification.object as? NSTextView else { return }
      convertTypedMarkdownConstructIfNeeded(in: textView)
      let encoded = JournalRichTextCodec.markdown(from: textView.attributedString())
      lastMarkdown = encoded
      parent.markdown = encoded
      publishSelection(in: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      publishSelection(in: textView)
    }

    private func convertTypedMarkdownConstructIfNeeded(in textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      let selection = textView.selectedRange()
      let paragraph = (storage.string as NSString).paragraphRange(for: selection)
      guard paragraph.length > 0 else { return }
      let source = (storage.string as NSString).substring(with: paragraph)
      guard JournalRichTextCodec.shouldRenderInline(in: source),
        (storage.attributes(at: paragraph.location, effectiveRange: nil)[JournalRichTextCodec.blockStyle] as? String) == "normal"
      else { return }
      isEditing = true
      let replacement = JournalRichTextCodec.render(source, images: parent.images)
      storage.replaceCharacters(in: paragraph, with: replacement)
      textView.setSelectedRange(NSRange(location: paragraph.location + replacement.length, length: 0))
      isEditing = false
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      if selector == #selector(NSResponder.deleteBackward(_:))
        || selector == #selector(NSResponder.deleteForward(_:)),
        let attachmentID = attachmentIDForDeletion(
          in: textView,
          forward: selector == #selector(NSResponder.deleteForward(_:))
        ) {
        parent.onRequestAttachmentRemoval(attachmentID)
        return true
      }

      if selector == #selector(NSResponder.insertTab(_:))
        || selector == #selector(NSResponder.insertBacktab(_:)) {
        return adjustListIndent(
          in: textView,
          delta: selector == #selector(NSResponder.insertTab(_:)) ? 2 : -2
        )
      }

      guard selector == #selector(NSResponder.insertNewline(_:)),
        let storage = textView.textStorage,
        storage.length > 0
      else { return false }
      var selection = textView.selectedRange()
      guard selection.length == 0 else { return false }
      let paragraph = (storage.string as NSString).paragraphRange(for: selection)
      let visibleLine = (storage.string as NSString).substring(with: paragraph)
      let attributes = storage.attributes(at: max(0, selection.location - 1), effectiveRange: nil)
      let renderedStyle = attributes[JournalRichTextCodec.blockStyle] as? String
      let sourceStyle = JournalRichTextCodec.listContext(forSourceLine: visibleLine)
      guard let style = (renderedStyle == "bullet" || renderedStyle == "ordered") ? renderedStyle : sourceStyle?.style,
        style == "bullet" || style == "ordered"
      else { return false }
      let number = (attributes[JournalRichTextCodec.orderedNumber] as? Int) ?? sourceStyle?.number
      let indent = (attributes[JournalRichTextCodec.listIndent] as? Int) ?? sourceStyle?.indent ?? 0

      if renderedStyle != style {
        isEditing = true
        let rendered = JournalRichTextCodec.render(visibleLine, images: parent.images)
        storage.replaceCharacters(in: paragraph, with: rendered)
        isEditing = false
        selection = NSRange(location: paragraph.location + rendered.length, length: 0)
        textView.setSelectedRange(selection)
      }
      let continuation = JournalRichTextCodec.nextListItem(
        afterVisibleLine: visibleLine,
        style: style,
        indent: indent,
        number: number
      )

      if continuation.isEmpty {
        let markerLength = JournalRichTextCodec.visibleMarkerLength(style: style, number: number)
        storage.replaceCharacters(
          in: NSRange(location: paragraph.location, length: min(markerLength, paragraph.length)),
          with: ""
        )
        textView.setSelectedRange(NSRange(location: paragraph.location, length: 0))
        textView.didChangeText()
        return true
      }

      let inserted = NSMutableAttributedString(string: "\n")
      inserted.append(JournalRichTextCodec.visibleListMarker(
        style: style,
        indent: indent,
        number: style == "ordered" ? (number ?? 1) + 1 : nil
      ))
      storage.replaceCharacters(in: selection, with: inserted)
      textView.setSelectedRange(NSRange(location: selection.location + inserted.length, length: 0))
      textView.didChangeText()
      return true
    }

    func publishSelection(in textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      let selection = textView.selectedRange()
      let safeLocation = min(max(selection.location, 0), storage.length)
      let attributeLocation = storage.length == 0 ? nil : min(max(safeLocation - (safeLocation == storage.length ? 1 : 0), 0), storage.length - 1)
      let styleName = attributeLocation.map {
        storage.attributes(at: $0, effectiveRange: nil)[JournalRichTextCodec.blockStyle] as? String
      } ?? (textView.typingAttributes[JournalRichTextCodec.blockStyle] as? String)
      let style = styleName.flatMap(JournalBlockStyle.init(rawValue:)) ?? .normal
      let selectedText: String
      if selection.length > 0, NSMaxRange(selection) <= storage.length {
        selectedText = (storage.string as NSString).substring(with: selection)
          .replacingOccurrences(of: "\u{FFFC}", with: "")
      } else {
        selectedText = ""
      }
      parent.onSelectionChange(.init(
        style: style,
        selectedText: selectedText,
        attachmentID: selectedAttachmentID(in: textView)
      ))
    }

    private func selectedAttachmentID(in textView: NSTextView) -> JournalAttachmentID? {
      guard let storage = textView.textStorage, storage.length > 0 else { return nil }
      let selection = textView.selectedRange()
      guard selection.length > 0 else { return nil }
      let locations = Array(selection.location..<min(NSMaxRange(selection), storage.length))
      for location in locations where location >= 0 && location < storage.length {
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        guard let rawID = attributes[JournalRichTextCodec.attachmentID] as? String,
          let uuid = UUID(uuidString: rawID)
        else { continue }
        return JournalAttachmentID(rawValue: uuid)
      }
      return nil
    }

    private func attachmentIDForDeletion(in textView: NSTextView, forward: Bool) -> JournalAttachmentID? {
      if let selected = selectedAttachmentID(in: textView) { return selected }
      guard let storage = textView.textStorage, storage.length > 0 else { return nil }
      let selection = textView.selectedRange()
      guard selection.length == 0 else { return nil }
      let location = forward ? selection.location : selection.location - 1
      guard location >= 0, location < storage.length,
        let rawID = storage.attributes(at: location, effectiveRange: nil)[JournalRichTextCodec.attachmentID] as? String,
        let uuid = UUID(uuidString: rawID)
      else { return nil }
      return JournalAttachmentID(rawValue: uuid)
    }

    private func adjustListIndent(in textView: NSTextView, delta: Int) -> Bool {
      guard let storage = textView.textStorage, storage.length > 0 else { return false }
      let selection = textView.selectedRange()
      let paragraph = (storage.string as NSString).paragraphRange(for: selection)
      let attributes = storage.attributes(at: min(paragraph.location, storage.length - 1), effectiveRange: nil)
      guard let styleName = attributes[JournalRichTextCodec.blockStyle] as? String,
        styleName == JournalBlockStyle.bullet.rawValue || styleName == JournalBlockStyle.ordered.rawValue
      else { return false }
      let current = attributes[JournalRichTextCodec.listIndent] as? Int ?? 0
      let next = min(max(current + delta, 0), 12)
      guard next != current else { return true }
      storage.addAttribute(JournalRichTextCodec.listIndent, value: next, range: paragraph)
      let paragraphStyle = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        ?? NSMutableParagraphStyle()
      paragraphStyle.headIndent = CGFloat(next) * 16
      paragraphStyle.firstLineHeadIndent = CGFloat(next) * 16
      storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
      textView.didChangeText()
      return true
    }

    func replaceDocument(in textView: NSTextView, markdown: String) {
      isEditing = true
      textView.textStorage?.setAttributedString(JournalRichTextCodec.render(markdown, images: parent.images))
      isEditing = false
      lastMarkdown = markdown
      publishSelection(in: textView)
    }

    func insertImage(_ image: JournalImageAttachment, id: JournalAttachmentID, in textView: NSTextView) {
      let attachment = NSTextAttachment()
      attachment.image = parent.images[id]
      attachment.bounds = JournalRichTextCodec.attachmentBounds(for: parent.images[id])
      let inserted = NSMutableAttributedString(attachment: attachment)
      inserted.addAttribute(JournalRichTextCodec.attachmentID, value: id.rawValue.uuidString, range: NSRange(location: 0, length: 1))
      inserted.addAttribute(JournalRichTextCodec.altText, value: image.relativeFileKey.rawValue, range: NSRange(location: 0, length: 1))
      let range = textView.selectedRange()
      textView.textStorage?.replaceCharacters(in: range, with: inserted)
      textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
      textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    func apply(_ command: JournalEditorCommand, in textView: NSTextView) {
      let storage = textView.textStorage
      let range = textView.selectedRange()
      let paragraph = (storage?.string as NSString?)?.paragraphRange(for: range) ?? range
      switch command {
      case .style(let style):
        guard let storage else { return }
        let existing = paragraph.location < storage.length
          ? storage.attributes(at: paragraph.location, effectiveRange: nil)[JournalRichTextCodec.blockStyle] as? String
          : nil
        var adjustedParagraph = paragraph
        var adjustedRange = range
        if existing == JournalBlockStyle.bullet.rawValue || existing == JournalBlockStyle.ordered.rawValue {
          let number = paragraph.location < storage.length
            ? storage.attributes(at: paragraph.location, effectiveRange: nil)[JournalRichTextCodec.orderedNumber] as? Int
            : nil
          let markerLength = JournalRichTextCodec.visibleMarkerLength(style: existing ?? "", number: number)
          let removable = min(markerLength, adjustedParagraph.length)
          storage.deleteCharacters(in: NSRange(location: adjustedParagraph.location, length: removable))
          adjustedParagraph.length -= removable
          adjustedRange.location = max(adjustedParagraph.location, adjustedRange.location - removable)
        }
        let styleAttributes = JournalRichTextCodec.attributes(
          style: style.rawValue,
          indent: 0,
          orderedNumber: nil
        )
        if adjustedParagraph.length > 0 {
          storage.addAttributes(styleAttributes, range: adjustedParagraph)
        }
        textView.typingAttributes = styleAttributes
        if style == .bullet || style == .ordered {
          let marker = JournalRichTextCodec.visibleListMarker(
            style: style.rawValue,
            indent: 0,
            number: style == .ordered ? 1 : nil
          )
          storage.insert(marker, at: adjustedParagraph.location)
          adjustedRange.location += marker.length
        }
        textView.setSelectedRange(adjustedRange)
      case .insertLink(let label, let destination):
        let inserted = NSAttributedString(
          string: label,
          attributes: [
            .link: destination,
            .font: JournalRichTextCodec.font(for: JournalBlockStyle.normal.rawValue),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
        )
        storage?.replaceCharacters(in: range, with: inserted)
        textView.setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
      case .insertText(let text):
        let source = storage?.string as NSString? ?? NSString(string: "")
        let separator = range.location > 0 && !source.substring(to: min(range.location, source.length)).hasSuffix("\n") ? "\n\n" : ""
        let inserted = NSAttributedString(
          string: separator + text,
          attributes: JournalRichTextCodec.attributes(style: JournalBlockStyle.normal.rawValue, indent: 0, orderedNumber: nil)
        )
        storage?.replaceCharacters(in: range, with: inserted)
        textView.setSelectedRange(NSRange(location: range.location + inserted.length, length: 0))
      }
      textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
      publishSelection(in: textView)
    }
  }
}

enum JournalRichTextCodec {
  static let blockStyle = NSAttributedString.Key("dayday.journal.block-style")
  static let attachmentID = NSAttributedString.Key("dayday.journal.attachment-id")
  static let altText = NSAttributedString.Key("dayday.journal.attachment-alt")
  static let listIndent = NSAttributedString.Key("dayday.journal.list-indent")
  static let orderedNumber = NSAttributedString.Key("dayday.journal.ordered-number")

  static func font(for style: String) -> NSFont {
    style == "heading" ? .systemFont(ofSize: 28, weight: .semibold) : .systemFont(ofSize: 18)
  }

  static func attachmentBounds(for image: NSImage?) -> NSRect {
    guard let image, image.size.width > 0, image.size.height > 0 else {
      return .init(x: 0, y: 0, width: 240, height: 160)
    }
    let maximum = NSSize(width: 360, height: 320)
    let scale = min(maximum.width / image.size.width, maximum.height / image.size.height, 1)
    return .init(
      x: 0,
      y: 0,
      width: image.size.width * scale,
      height: image.size.height * scale
    )
  }

  static func render(_ markdown: String, images: [JournalAttachmentID: NSImage]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    for (lineIndex, rawLine) in lines.enumerated() {
      let line = String(rawLine)
      let block = block(from: line)
      append(
        block.content,
        style: block.style,
        indent: block.indent,
        orderedNumber: block.orderedNumber,
        images: images,
        into: result
      )
      if lineIndex < lines.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: attributes(
          style: block.style,
          indent: block.indent,
          orderedNumber: block.orderedNumber
        )))
      }
    }
    return result
  }

  static func markdown(from attributed: NSAttributedString) -> String {
    let source = attributed.string as NSString
    var lines: [String] = []
    var line = ""
    var lineStyle = "normal"
    var lineIndent = 0
    var lineNumber: Int?
    var index = 0
    while index < source.length {
      let attributes = attributed.attributes(at: index, effectiveRange: nil)
      lineStyle = (attributes[blockStyle] as? String) ?? lineStyle
      lineIndent = (attributes[listIndent] as? Int) ?? lineIndent
      lineNumber = (attributes[orderedNumber] as? Int) ?? lineNumber
      let character = source.character(at: index)
      if character == 10 {
        lines.append(prefix(for: lineStyle, indent: lineIndent, number: lineNumber) + content(line, for: lineStyle, number: lineNumber))
        line = ""; lineStyle = "normal"; lineIndent = 0; lineNumber = nil; index += 1; continue
      }
      if character == 0xFFFC, let rawID = attributes[attachmentID] as? String {
        line += "![图片](dayday-attachment://\(rawID.lowercased()))"
      } else if let link = linkURL(from: attributes) {
        let previousLink = index > 0
          ? linkURL(from: attributed.attributes(at: index - 1, effectiveRange: nil))
          : nil
        if previousLink != link { line += "[" }
        line += source.substring(with: NSRange(location: index, length: 1))
        let nextLink = index + 1 < source.length
          ? linkURL(from: attributed.attributes(at: index + 1, effectiveRange: nil))
          : nil
        if nextLink != link { line += "](\(link))" }
      } else {
        line += source.substring(with: NSRange(location: index, length: 1))
      }
      index += 1
    }
    lines.append(prefix(for: lineStyle, indent: lineIndent, number: lineNumber) + content(line, for: lineStyle, number: lineNumber))
    return lines.joined(separator: "\n")
  }

  private static func block(from line: String) -> (style: String, content: String, indent: Int, orderedNumber: Int?) {
    let indent = line.prefix { $0 == " " }.count
    let source = String(line.dropFirst(indent))
    if source.hasPrefix("## ") { return ("heading", String(source.dropFirst(3)), indent, nil) }
    if source.hasPrefix("- ") || source.hasPrefix("* ") || source.hasPrefix("+ ") {
      return ("bullet", String(source.dropFirst(2)), indent, nil)
    }
    if source.hasPrefix("> ") { return ("quote", String(source.dropFirst(2)), indent, nil) }
    if let marker = orderedListMarker(in: source) {
      return ("ordered", String(source.dropFirst(marker.length)), indent, marker.number)
    }
    return ("normal", line, 0, nil)
  }

  private static func prefix(for style: String, indent: Int, number: Int?) -> String {
    let leading = String(repeating: " ", count: indent)
    let marker: String
    switch style {
    case "heading": marker = "## "
    case "bullet": marker = "- "
    case "ordered": marker = "\(number ?? 1). "
    case "quote": marker = "> "
    default: marker = ""
    }
    return leading + marker
  }

  private static func content(_ visibleLine: String, for style: String, number: Int?) -> String {
    if style == "bullet", visibleLine.hasPrefix("• ") { return String(visibleLine.dropFirst(2)) }
    if style == "ordered", let number {
      let marker = "\(number). "
      if visibleLine.hasPrefix(marker) { return String(visibleLine.dropFirst(marker.count)) }
    }
    return visibleLine
  }

  private static func append(
    _ source: String,
    style: String,
    indent: Int,
    orderedNumber: Int?,
    images: [JournalAttachmentID: NSImage],
    into result: NSMutableAttributedString
  ) {
    if style == "bullet" || style == "ordered" {
      result.append(visibleListMarker(style: style, indent: indent, number: orderedNumber))
    }
    let expression = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(dayday-attachment://([0-9A-Fa-f-]{36})\)"#)
    let text = source as NSString
    let matches = expression?.matches(in: source, range: NSRange(location: 0, length: text.length)) ?? []
    var cursor = 0
    for match in matches {
      if match.range.location > cursor { appendText(text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), style: style, indent: indent, orderedNumber: orderedNumber, into: result) }
      let rawID = text.substring(with: match.range(at: 1))
      if let uuid = UUID(uuidString: rawID) {
        let attachment = NSTextAttachment(); attachment.image = images[JournalAttachmentID(rawValue: uuid)]
        attachment.bounds = attachmentBounds(for: attachment.image)
        let inserted = NSMutableAttributedString(attachment: attachment)
        inserted.addAttributes(attributes(style: style, indent: indent, orderedNumber: orderedNumber).merging([attachmentID: rawID]) { _, right in right }, range: NSRange(location: 0, length: 1))
        result.append(inserted)
      }
      cursor = NSMaxRange(match.range)
    }
    if cursor < text.length { appendText(text.substring(from: cursor), style: style, indent: indent, orderedNumber: orderedNumber, into: result) }
  }

  private static func appendText(_ text: String, style: String, indent: Int, orderedNumber: Int?, into result: NSMutableAttributedString) {
    let attributes = attributes(style: style, indent: indent, orderedNumber: orderedNumber)
    let source = text as NSString
    let matches = markdownLinkExpression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    var cursor = 0
    for match in matches {
      if match.range.location > cursor {
        result.append(NSAttributedString(
          string: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
          attributes: attributes
        ))
      }
      let label = source.substring(with: match.range(at: 1))
      let destination = source.substring(with: match.range(at: 2))
      var linkAttributes = attributes
      linkAttributes[.foregroundColor] = NSColor.linkColor
      linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      linkAttributes[.link] = URL(string: destination) ?? destination
      result.append(NSAttributedString(string: label, attributes: linkAttributes))
      cursor = NSMaxRange(match.range)
    }
    if cursor < source.length {
      result.append(NSAttributedString(string: source.substring(from: cursor), attributes: attributes))
    }
  }

  private static let markdownLinkExpression = try! NSRegularExpression(
    pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#
  )

  private static func linkURL(from attributes: [NSAttributedString.Key: Any]) -> String? {
    if let url = attributes[.link] as? URL { return url.absoluteString }
    if let url = attributes[.link] as? String { return url }
    return nil
  }

  static func nextListItem(afterVisibleLine line: String, style: String, indent: Int, number: Int?) -> String {
    let markerLength = visibleMarkerLength(style: style, number: number)
    let content = line.dropFirst(min(markerLength, line.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { return "" }
    if style == "ordered" { return String(repeating: " ", count: indent) + "\((number ?? 1) + 1). " }
    return String(repeating: " ", count: indent) + "- "
  }

  static func visibleMarkerLength(style: String, number: Int?) -> Int {
    style == "ordered" ? "\(number ?? 1). ".count : 2
  }

  static func visibleListMarker(style: String, indent: Int, number: Int?) -> NSAttributedString {
    let display = style == "ordered" ? "\(number ?? 1). " : "• "
    return NSAttributedString(
      string: display,
      attributes: attributes(style: style, indent: indent, orderedNumber: number)
    )
  }

  static func listContext(forSourceLine line: String) -> (style: String, indent: Int, number: Int?)? {
    let parsed = block(from: line)
    guard parsed.style == "bullet" || parsed.style == "ordered" else { return nil }
    return (parsed.style, parsed.indent, parsed.orderedNumber)
  }

  static func shouldRenderInline(in line: String) -> Bool {
    block(from: line).style != "normal" || markdownLinkExpression.firstMatch(
      in: line,
      range: NSRange(location: 0, length: (line as NSString).length)
    ) != nil
  }

  static func attributes(style: String, indent: Int, orderedNumber: Int?) -> [NSAttributedString.Key: Any] {
    var result: [NSAttributedString.Key: Any] = [
      .font: font(for: style),
      blockStyle: style,
      listIndent: indent,
      .foregroundColor: style == "quote" ? NSColor.secondaryLabelColor : NSColor.labelColor,
    ]
    if let orderedNumber { result[Self.orderedNumber] = orderedNumber }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 5
    paragraph.paragraphSpacing = 8
    if indent > 0 {
      paragraph.headIndent = CGFloat(indent) * 16
      paragraph.firstLineHeadIndent = CGFloat(indent) * 16
    }
    result[.paragraphStyle] = paragraph
    return result
  }

  private static func orderedListMarker(in source: String) -> (number: Int, length: Int)? {
    let digits = source.prefix { $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits), source.dropFirst(digits.count).hasPrefix(". ") else { return nil }
    return (number, digits.count + 2)
  }
}

private struct MarkdownJournalPreview: View {
  let markdown: String
  @ObservedObject var attachments: JournalAttachmentModel

  var body: some View {
    DaydayScrollView {
      Group {
        if markdown.isEmpty {
          ContentUnavailableView(
            "还没有可预览的内容",
            systemImage: "text.alignleft",
            description: Text("开始书写后，Markdown 会在这里以阅读版式呈现。")
          )
          .frame(maxWidth: .infinity, minHeight: 320)
        } else {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(MarkdownJournalBlock.parse(markdown), id: \.id) { block in
              switch block.content {
              case .text(let source):
                MarkdownJournalText(source: source)
              case .image(let attachmentID, let altText):
                JournalInlineImage(
                  image: attachments.image(for: attachmentID),
                  altText: altText
                )
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.bottom, 44)
    }
    .accessibilityLabel("日记 Markdown 阅读预览")
  }
}

private struct MarkdownJournalText: View {
  let source: String

  var body: some View {
    if let rendered = try? AttributedString(
      markdown: source,
      options: .init(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    ) {
      Text(rendered)
        .font(.body)
        .lineSpacing(6)
        .textSelection(.enabled)
    } else {
      Text(source)
        .font(.body)
        .lineSpacing(6)
        .textSelection(.enabled)
    }
  }
}

private struct JournalInlineImage: View {
  let image: NSImage?
  let altText: String

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 680, maxHeight: 520, alignment: .leading)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      } else {
        Label(altText, systemImage: "photo")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel("日记内图片：\(altText)")
  }
}

private struct MarkdownJournalBlock: Identifiable {
  enum Content {
    case text(String)
    case image(JournalAttachmentID, String)
  }

  let id: String
  let content: Content

  static func parse(_ markdown: String) -> [Self] {
    let pattern = #"!\[((?:\\.|[^\]])*)\]\(dayday-attachment://([0-9A-Fa-f-]{36})\)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return [.init(id: "text-0", content: .text(markdown))]
    }
    let source = markdown as NSString
    let matches = expression.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return [.init(id: "text-0", content: .text(markdown))] }

    var blocks: [Self] = []
    var cursor = 0
    for (index, match) in matches.enumerated() {
      if match.range.location > cursor {
        blocks.append(.init(
          id: "text-\(index)",
          content: .text(source.substring(with: NSRange(
            location: cursor, length: match.range.location - cursor)))
        ))
      }
      let altText = source.substring(with: match.range(at: 1))
        .replacing("\\]", with: "]")
        .replacing("\\\\", with: "\\")
      let rawID = source.substring(with: match.range(at: 2))
      if let uuid = UUID(uuidString: rawID) {
        blocks.append(.init(
          id: "image-\(rawID)-\(index)",
          content: .image(JournalAttachmentID(rawValue: uuid), altText)
        ))
      } else {
        blocks.append(.init(
          id: "text-image-\(index)",
          content: .text(source.substring(with: match.range))
        ))
      }
      cursor = NSMaxRange(match.range)
    }
    if cursor < source.length {
      blocks.append(.init(
        id: "text-tail",
        content: .text(source.substring(from: cursor))
      ))
    }
    return blocks
  }
}

private struct JournalReviewSidebar: View {
  @ObservedObject var history: JournalHistoryModel
  @ObservedObject var journal: JournalEntryModel
  let selectDate: (Date) -> Void

  var body: some View {
    DaydayThemeReader { theme, _ in
      let palette = DaydayWritingReviewPalette(theme: theme)
      sidebarContent(palette: palette)
        .tint(palette.action.color)
    }
  }

  private func sidebarContent(palette: DaydayWritingReviewPalette) -> some View {
    DaydayScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        Text("日记回顾")
          .font(.title3.weight(.semibold))

        DaydayWritingHistoryCalendar(
          characterCounts: history.calendarCharacterCounts,
          selectedDay: journal.presentedDay,
          palette: palette,
          artifactName: "日记",
          allowsEmptySelection: true,
          selectDate: selectDate
        )

        DaydayWritingHeatmap(
          presentation: history.heatmapPresentation,
          selectedDay: journal.presentedDay,
          palette: palette,
          artifactName: "日记",
          allowsEmptySelection: true,
          selectDate: selectDate
        )

        DaydayCompactWritingStatistics(
          totalCharacterCount: history.statistics.totalCharacterCount,
          writingDayCount: history.statistics.writingDayCount,
          currentStreak: history.statistics.currentStreak
        )

        VStack(alignment: .leading, spacing: 8) {
          Text("日记列表")
            .font(.headline)
          TextField("搜索日记内容", text: $history.searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("搜索日记内容")
        }

        if history.filteredEntries.isEmpty {
          ContentUnavailableView(
            history.entries.isEmpty ? "还没有历史日记" : "没有匹配的日记",
            systemImage: history.entries.isEmpty ? "book.closed" : "magnifyingglass",
            description: Text(history.status)
          )
          .frame(maxWidth: .infinity, minHeight: 150)
        } else {
          LazyVStack(spacing: 6) {
            ForEach(history.filteredEntries, id: \.entry.id) { record in
              Button {
                selectDate(record.day.boundary.startsAt)
              } label: {
                JournalReviewEntryRow(
                  record: record,
                  isSelected: journal.presentedDay?.id == record.day.id,
                  characterCount: history.characterCount(for: record),
                  previewText: history.previewText(for: record.entry.id),
                  palette: palette
                )
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                "\(JournalDateFormatting.dayTitle(record.day))，"
                  + "\(history.characterCount(for: record)) 字，打开日记"
              )
            }
          }
        }

        Label("内容仅保存在本机，不进入工作日报", systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)
    }
  }
}

private struct JournalHistoryEntryDetail: View {
  let record: PersistedJournalEntryRecord
  @ObservedObject var attachments: JournalAttachmentModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: "\(record.day.logicalDate.year)年\(record.day.logicalDate.month)月\(record.day.logicalDate.day)日")
        .font(.title2.weight(.semibold))
      Text(JournalDateFormatting.timestamp(record.entry.updatedAt))
        .font(.caption)
        .foregroundStyle(.secondary)
      Divider()
      MarkdownJournalPreview(markdown: record.currentOriginal.body, attachments: attachments)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct DaydayCompactWritingStatistics: View {
  let totalCharacterCount: Int
  let writingDayCount: Int
  let currentStreak: Int

  var body: some View {
    HStack(spacing: 0) {
      metric(totalCharacterCount.formatted(), title: "累计字数")
      Divider().frame(height: 30)
      metric(writingDayCount.formatted(), title: "记录天数")
      Divider().frame(height: 30)
      metric(currentStreak.formatted(), title: "连续记录")
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "累计 \(totalCharacterCount) 字，记录 \(writingDayCount) 天，"
        + "连续记录 \(currentStreak) 天"
    )
  }

  private func metric(_ value: String, title: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.callout.weight(.semibold))
        .monospacedDigit()
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct JournalReviewEntryRow: View {
  let record: PersistedJournalEntryRecord
  let isSelected: Bool
  let characterCount: Int
  let previewText: String
  let palette: DaydayWritingReviewPalette

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(JournalDateFormatting.dayTitle(record.day))
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text("\(characterCount) 字")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text(previewText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      isSelected ? palette.selectionFill.color : Color.secondary.opacity(0.045),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(palette.selectionBorder.color.opacity(0.45), lineWidth: 1)
      }
    }
  }
}

struct DaydayWritingHeatmap: View {
  let presentation: JournalWritingHeatmapPresentation
  let selectedDay: DayDescriptor?
  let palette: DaydayWritingReviewPalette
  let artifactName: String
  let allowsEmptySelection: Bool
  let selectDate: (Date) -> Void

  @State private var hoveredCell: JournalWritingHeatmapCell?

  var body: some View {
    let presentation = presentation
    let activeCell = hoveredCell ?? selectedCell(in: presentation)
    VStack(alignment: .leading, spacing: 9) {
      DaydayHeatmapHoverSummary(
        text: activeCell.map(summaryText) ?? "悬浮查看每天的实际字数",
        isActive: activeCell != nil,
        activeSystemImage: "textformat.size",
        activeTint: palette.action.color
      )

      GeometryReader { proxy in
        let layout = DaydayCalendarHeatmapLayout.fitting(
          availableWidth: proxy.size.width,
          columnCount: presentation.weekCount,
          maximumCellSize: 9
        )
        Canvas { context, _ in
          for (index, cell) in presentation.cells.enumerated() {
            let rect = DaydayWritingHeatmapGeometry.cellRect(at: index, layout: layout)
            context.fill(
              Path(roundedRect: rect, cornerRadius: 2.5),
              with: .color(
                cell.isFuture
                  ? Color.secondary.opacity(0.035)
                  : DaydayHeatmapScale.color(
                    tint: palette.action.color,
                    value: Double(cell.characterCount),
                    maximum: Double(max(1, presentation.maximumCharacterCount))
                  )
              )
            )
            if isSelected(cell.date) {
              context.stroke(
                Path(roundedRect: rect, cornerRadius: 2.5),
                with: .color(palette.selectionBorder.color),
                lineWidth: 1.5
              )
            }
          }
        }
        .frame(width: layout.width, height: layout.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
          switch phase {
          case .active(let location):
            hoveredCell = cell(at: location, layout: layout)
          case .ended:
            hoveredCell = nil
          }
        }
        .gesture(
          SpatialTapGesture()
            .onEnded { value in
              guard let cell = cell(at: value.location, layout: layout),
                !cell.isFuture,
                allowsEmptySelection || cell.hasEntry
              else { return }
              selectDate(cell.date)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近 26 周\(artifactName)记录")
        .accessibilityValue(activeCell.map(summaryText) ?? "悬浮查看每天的实际字数")
        .accessibilityHint("可在上方日历或下方列表中按日期打开\(artifactName)")
      }
      .frame(height: 76)

      DaydayHeatmapContinuousLegend(
        title: "",
        tint: palette.action.color,
        maximumLabel: presentation.maximumCharacterCount.formatted(),
        unitDetail: "最近 26 周",
        showsTitle: false
      )
    }
  }

  private func cell(
    at location: CGPoint,
    layout: DaydayCalendarHeatmapLayout
  ) -> JournalWritingHeatmapCell? {
    guard let index = DaydayWritingHeatmapGeometry.cellIndex(
      at: location,
      layout: layout,
      cellCount: presentation.cells.count
    ) else { return nil }
    return presentation.cells[index]
  }

  private func selectedCell(
    in presentation: JournalWritingHeatmapPresentation
  ) -> JournalWritingHeatmapCell? {
    presentation.cells.first { isSelected($0.date) }
  }

  private func isSelected(_ date: Date) -> Bool {
    guard let selectedDay else { return false }
    let components = Calendar.autoupdatingCurrent.dateComponents(
      [.year, .month, .day],
      from: date
    )
    return selectedDay.logicalDate.year == components.year
      && selectedDay.logicalDate.month == components.month
      && selectedDay.logicalDate.day == components.day
  }

  private func summaryText(_ cell: JournalWritingHeatmapCell) -> String {
    "\(JournalDateFormatting.dayTitle(cell.date)) · \(cell.characterCount.formatted()) 字"
  }

}

enum DaydayWritingHeatmapGeometry {
  static func cellRect(
    at index: Int,
    layout: DaydayCalendarHeatmapLayout
  ) -> CGRect {
    let column = index / layout.rowCount
    let row = index % layout.rowCount
    return CGRect(
      x: CGFloat(column) * (layout.cellSize + layout.columnSpacing),
      y: CGFloat(row) * (layout.cellSize + layout.rowSpacing),
      width: layout.cellSize,
      height: layout.cellSize
    )
  }

  static func cellIndex(
    at location: CGPoint,
    layout: DaydayCalendarHeatmapLayout,
    cellCount: Int
  ) -> Int? {
    guard location.x >= 0, location.y >= 0,
      location.x < layout.width, location.y < layout.height
    else { return nil }
    let columnStep = layout.cellSize + layout.columnSpacing
    let rowStep = layout.cellSize + layout.rowSpacing
    guard columnStep > 0, rowStep > 0 else { return nil }
    let column = Int(location.x / columnStep)
    let row = Int(location.y / rowStep)
    guard column < layout.columnCount, row < layout.rowCount else { return nil }
    let localX = location.x - CGFloat(column) * columnStep
    let localY = location.y - CGFloat(row) * rowStep
    guard localX <= layout.cellSize, localY <= layout.cellSize else { return nil }
    let index = column * layout.rowCount + row
    return index < cellCount ? index : nil
  }
}

struct DaydayWritingHistoryCalendar: View {
  let characterCounts: [JournalLogicalDayKey: Int]
  let selectedDay: DayDescriptor?
  let palette: DaydayWritingReviewPalette
  let artifactName: String
  let allowsEmptySelection: Bool
  let selectDate: (Date) -> Void

  @State private var displayedMonth: Date
  @State private var navigationDirection = 1

  private let calendar = Calendar.autoupdatingCurrent
  private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

  init(
    characterCounts: [JournalLogicalDayKey: Int],
    selectedDay: DayDescriptor?,
    palette: DaydayWritingReviewPalette,
    artifactName: String,
    allowsEmptySelection: Bool,
    selectDate: @escaping (Date) -> Void
  ) {
    self.characterCounts = characterCounts
    self.selectedDay = selectedDay
    self.palette = palette
    self.artifactName = artifactName
    self.allowsEmptySelection = allowsEmptySelection
    self.selectDate = selectDate
    _displayedMonth = State(initialValue: selectedDay?.boundary.startsAt ?? .now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(JournalDateFormatting.monthTitle(displayedMonth))
          .font(.headline)
        Spacer()
        Button("今天") {
          moveToToday()
          selectDate(.now)
        }
        .buttonStyle(.link)
        .font(.caption)
        Button("上月", systemImage: "chevron.left") { moveMonth(by: -1) }
          .labelStyle(.iconOnly)
          .accessibilityLabel("查看上个月")
        Button("下月", systemImage: "chevron.right") { moveMonth(by: 1) }
          .labelStyle(.iconOnly)
          .accessibilityLabel("查看下个月")
          .disabled(!canMoveToNextMonth)
      }
      ZStack {
        calendarGrid
          .id(monthID)
          .transition(monthTransition)
      }
      .clipped()
      .contentShape(Rectangle())
      .gesture(monthSwipeGesture)
    }
    .onChange(of: selectedDay?.id) {
      guard let selectedDay else { return }
      let selectedMonth = calendar.dateInterval(
        of: .month,
        for: selectedDay.boundary.startsAt
      )?.start ?? selectedDay.boundary.startsAt
      let visibleMonth = calendar.dateInterval(of: .month, for: displayedMonth)?.start
        ?? displayedMonth
      guard selectedMonth != visibleMonth else { return }
      displayedMonth = selectedMonth
    }
  }

  private var calendarGrid: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7),
      spacing: 3
    ) {
      ForEach(weekdaySymbols, id: \.self) { symbol in
        Text(symbol)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
      ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, day in
        if let day {
          calendarCell(for: day)
        } else {
          Color.clear.frame(height: 30)
        }
      }
    }
  }

  @ViewBuilder
  private func calendarCell(for day: Date) -> some View {
    let characterCount = characterCount(on: day)
    let isSelected = isSelected(day)
    let isToday = calendar.isDateInToday(day)
    let isFuture = calendar.startOfDay(for: day) > calendar.startOfDay(for: .now)
    Button {
      selectDate(day)
    } label: {
      ZStack(alignment: .bottom) {
        Text(day.formatted(.dateTime.day()))
          .font(.caption.weight(characterCount == nil ? .regular : .semibold))
          .foregroundStyle(isFuture ? .tertiary : .primary)
          .frame(maxWidth: .infinity, minHeight: 30)
        if characterCount != nil {
          Circle()
            .fill(palette.action.color)
            .frame(width: 4, height: 4)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
        }
      }
      .background(
        isSelected ? palette.selectionFill.color : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        if isToday, !isSelected {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(palette.selectionBorder.color.opacity(0.55), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(isFuture || (!allowsEmptySelection && characterCount == nil))
    .accessibilityLabel(
      accessibilityLabel(for: day, characterCount: characterCount, isSelected: isSelected)
    )
  }

  private var daysInGrid: [Date?] {
    guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
      let count = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
    else { return [] }
    let leading = calendar.component(.weekday, from: interval.start) - 1
    let days = (0..<count).compactMap {
      calendar.date(byAdding: .day, value: $0, to: interval.start)
    }
    let leadingDays = Array<Date?>(repeating: nil, count: leading)
    let populated = leadingDays + days.map(Optional.some)
    return populated + Array(repeating: nil, count: max(0, 42 - populated.count))
  }

  private func characterCount(on date: Date) -> Int? {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return characterCounts[
      JournalLogicalDayKey(
        year: components.year ?? 0,
        month: components.month ?? 0,
        day: components.day ?? 0
      )
    ]
  }

  private func isSelected(_ date: Date) -> Bool {
    guard let selectedDay else { return false }
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return selectedDay.logicalDate.year == components.year
      && selectedDay.logicalDate.month == components.month
      && selectedDay.logicalDate.day == components.day
  }

  private func accessibilityLabel(
    for date: Date,
    characterCount: Int?,
    isSelected: Bool
  ) -> String {
    var parts = [JournalDateFormatting.shortDayTitle(date)]
    if let characterCount {
      parts.append("\(artifactName)已记录 \(characterCount) 字")
    } else {
      parts.append("未记录" + (allowsEmptySelection ? "，可补写" : ""))
    }
    if isSelected { parts.append("当前正在编辑") }
    return parts.joined(separator: "，")
  }

  private var canMoveToNextMonth: Bool {
    guard let displayed = calendar.dateInterval(of: .month, for: displayedMonth)?.start,
      let current = calendar.dateInterval(of: .month, for: .now)?.start
    else { return true }
    return displayed < current
  }

  private func moveMonth(by offset: Int) {
    guard offset < 0 || canMoveToNextMonth else { return }
    navigationDirection = offset < 0 ? -1 : 1
    withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
      displayedMonth = calendar.date(
        byAdding: .month,
        value: offset,
        to: displayedMonth
      ) ?? displayedMonth
    }
  }

  private func moveToToday() {
    let currentMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
    let displayedMonthStart =
      calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
    navigationDirection = displayedMonthStart <= currentMonth ? 1 : -1
    withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
      displayedMonth = .now
    }
  }


  private var monthID: String {
    let components = calendar.dateComponents([.year, .month], from: displayedMonth)
    return "\(components.year ?? 0)-\(components.month ?? 0)"
  }

  private var monthTransition: AnyTransition {
    let insertion: Edge = navigationDirection < 0 ? .leading : .trailing
    let removal: Edge = navigationDirection < 0 ? .trailing : .leading
    return .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }

  private var monthSwipeGesture: some Gesture {
    DragGesture(minimumDistance: 18)
      .onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height),
          abs(value.translation.width) >= 36
        else { return }
        moveMonth(by: value.translation.width > 0 ? -1 : 1)
      }
  }
}

private struct JournalLocationMapSheet: View {
  let snapshot: JournalLocationSnapshot
  let placeName: String?
  @State private var position: MapCameraPosition

  init(snapshot: JournalLocationSnapshot, placeName: String?) {
    self.snapshot = snapshot
    self.placeName = placeName
    let accuracySpan = min(max(snapshot.horizontalAccuracy / 55_000, 0.002), 0.03)
    _position = State(initialValue: .region(.init(
      center: .init(latitude: snapshot.latitude, longitude: snapshot.longitude),
      span: .init(latitudeDelta: accuracySpan, longitudeDelta: accuracySpan)
    )))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(placeName ?? "记录位置")
          .font(.title3.weight(.semibold))
        Text("水平误差 ±\(Int(snapshot.horizontalAccuracy.rounded())) 米")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Map(position: $position) {
        Marker(placeName ?? "记录位置", coordinate: .init(
          latitude: snapshot.latitude,
          longitude: snapshot.longitude
        ))
      }
      .mapStyle(.standard)
      .mapControls {
        MapCompass()
        MapScaleView()
        MapZoomStepper()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text("地图由 Apple 地图服务提供；原始坐标与系统精度仍是日记保存的事实记录。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(minWidth: 480, idealWidth: 600, minHeight: 430, idealHeight: 520)
  }
}

enum JournalDateFormatting {
  static func dayTitle(_ date: Date) -> String {
    formatter("yyyy年M月d日 EEEE").string(from: date)
  }

  static func dayTitle(_ day: DayDescriptor) -> String {
    dayTitle(day.boundary.startsAt)
  }

  static func monthTitle(_ date: Date) -> String {
    formatter("yyyy年M月").string(from: date)
  }

  static func shortDayTitle(_ date: Date) -> String {
    formatter("M月d日").string(from: date)
  }

  static func timestamp(_ date: Date) -> String {
    formatter("M月d日 HH:mm").string(from: date)
  }

  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh-Hans_CN")
    formatter.calendar = Calendar.autoupdatingCurrent
    formatter.timeZone = TimeZone.autoupdatingCurrent
    formatter.dateFormat = format
    return formatter
  }
}
