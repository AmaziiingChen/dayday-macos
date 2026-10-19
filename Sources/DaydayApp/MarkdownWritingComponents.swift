import AppKit
import DaydayCore
import SwiftUI

enum DaydayWritingToolbarSymbol {
  static let format = "textformat"
  static let journalAI = "sparkles"
  static let insertImage = "photo.badge.plus"
  static let deleteImage = "trash"
  static let source = "chevron.left.forwardslash.chevron.right"
  static let preview = "doc.richtext"
  static let history = "clock.arrow.circlepath"
  static let export = "square.and.arrow.up"
  static let review = "sidebar.trailing"
  static let saveVersion = "square.and.arrow.down"
  static let finalize = "checkmark.seal"
}

enum DaydayWritingToolbarPresentation {
  static func isVisible(isActive: Bool) -> Bool { isActive }
}

private struct DaydayWritingToolbarIconStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .labelStyle(.iconOnly)
      .controlSize(.regular)
  }
}

private struct DaydayWritingToolbarLabeledStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .labelStyle(.titleAndIcon)
      .controlSize(.regular)
  }
}

extension View {
  func daydayWritingToolbarIcon() -> some View {
    modifier(DaydayWritingToolbarIconStyle())
  }

  func daydayWritingToolbarLabel() -> some View {
    modifier(DaydayWritingToolbarLabeledStyle())
  }
}

/// The common writing canvas for personal journals and work reports.
///
/// Both products intentionally share typography, Markdown behavior, loading/error treatment and
/// responsive margins. Their surrounding context remains separate: journals may supply private
/// attachments/location, while reports use work-safe AI controls and current weather context.
struct DaydayMarkdownWritingSurface<Context: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.daydayAccent) private var accent

  @Binding var markdown: String
  let title: String
  let placeholder: String
  let contentAccessibilityLabel: String
  let status: String
  let statusAccessibilityLabel: String
  let statusSystemImage: String
  let statusColor: Color
  let imageResources: [JournalAttachmentID: Data]
  let pendingAttachment: JournalAttachment?
  let attachmentRequest: Int
  let action: JournalMarkdownEditorAction?
  let actionRequest: Int
  let snapshotRequest: Int
  let isSourceMode: Bool
  let isReadOnly: Bool
  let isActive: Bool
  let onSelectionChange: @MainActor (JournalMarkEditSelectionState) -> Void
  let onRequestAttachmentRemoval: @MainActor (JournalAttachmentID) -> Void
  let onUserEdit: @MainActor () -> Void
  let onSnapshot: @MainActor (String?, Int) -> Void
  let context: Context

  @State private var editorState = JournalMarkEditState.loading
  @State private var editorReloadRequest = 0

  init(
    markdown: Binding<String>,
    title: String,
    placeholder: String,
    contentAccessibilityLabel: String,
    status: String,
    statusAccessibilityLabel: String,
    statusSystemImage: String,
    statusColor: Color,
    imageResources: [JournalAttachmentID: Data] = [:],
    pendingAttachment: JournalAttachment?,
    attachmentRequest: Int,
    action: JournalMarkdownEditorAction?,
    actionRequest: Int,
    snapshotRequest: Int = 0,
    isSourceMode: Bool,
    isReadOnly: Bool,
    isActive: Bool = true,
    onSelectionChange: @escaping @MainActor (JournalMarkEditSelectionState) -> Void,
    onRequestAttachmentRemoval: @escaping @MainActor (JournalAttachmentID) -> Void,
    onUserEdit: @escaping @MainActor () -> Void,
    onSnapshot: @escaping @MainActor (String?, Int) -> Void = { _, _ in },
    @ViewBuilder context: () -> Context
  ) {
    _markdown = markdown
    self.title = title
    self.placeholder = placeholder
    self.contentAccessibilityLabel = contentAccessibilityLabel
    self.status = status
    self.statusAccessibilityLabel = statusAccessibilityLabel
    self.statusSystemImage = statusSystemImage
    self.statusColor = statusColor
    self.imageResources = imageResources
    self.pendingAttachment = pendingAttachment
    self.attachmentRequest = attachmentRequest
    self.action = action
    self.actionRequest = actionRequest
    self.snapshotRequest = snapshotRequest
    self.isSourceMode = isSourceMode
    self.isReadOnly = isReadOnly
    self.isActive = isActive
    self.onSelectionChange = onSelectionChange
    self.onRequestAttachmentRemoval = onRequestAttachmentRemoval
    self.onUserEdit = onUserEdit
    self.onSnapshot = onSnapshot
    self.context = context()
  }

  var body: some View {
    VStack(spacing: 0) {
      writingHeader
        .frame(maxWidth: 792, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.horizontal, DaydaySpace.pageHorizontal)

      ZStack(alignment: .topLeading) {
        JournalMarkEditEditor(
          markdown: $markdown,
          placeholder: placeholder,
          editorTheme: editorTheme,
          imageResources: imageResources,
          pendingAttachment: pendingAttachment,
          attachmentRequest: attachmentRequest,
          action: action,
          actionRequest: actionRequest,
          snapshotRequest: snapshotRequest,
          reloadRequest: editorReloadRequest,
          isSourceMode: isSourceMode,
          isReadOnly: isReadOnly,
          isActive: isActive,
          accessibilityLabel: contentAccessibilityLabel,
          onStateChange: { editorState = $0 },
          onSelectionChange: onSelectionChange,
          onRequestAttachmentRemoval: onRequestAttachmentRemoval,
          onUserEdit: onUserEdit,
          onSnapshot: onSnapshot
        )
        .accessibilityLabel(contentAccessibilityLabel)

        if editorState != .ready {
          editorStateOverlay
        }
      }
      .padding(.top, 12)
    }
    .padding(.top, DaydaySpace.pageContentTop)
    .padding(.bottom, 20)
    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var editorTheme: DaydayMarkdownEditorTheme {
    let environment = DaydayThemeEnvironment(
      appearance: colorScheme == .dark ? .dark : .light,
      contrast: contrast == .increased ? .increased : .standard,
      reduceTransparency: reduceTransparency
    )
    return DaydayMarkdownEditorTheme(
      theme: .mineralCandidate(for: environment, accent: accent),
      increasedContrast: contrast == .increased
    )
  }

  private var writingHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.title3.weight(.semibold))

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          context
          Spacer(minLength: 8)
          statusLabel
        }
        VStack(alignment: .leading, spacing: 7) {
          context
          statusLabel
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var statusLabel: some View {
    Label(status, systemImage: statusSystemImage)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(statusColor)
      .accessibilityLabel("\(statusAccessibilityLabel)：\(status)")
  }

  @ViewBuilder
  private var editorStateOverlay: some View {
    switch editorState {
    case .loading:
      ProgressView("正在准备编辑器…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    case .failed:
      ContentUnavailableView {
        Label("编辑器未能载入", systemImage: "exclamationmark.triangle")
      } description: {
        Text("已保存的内容没有受到影响，可以重新载入编辑器。")
      } actions: {
        Button("重新载入") { editorReloadRequest += 1 }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background)
    case .ready:
      EmptyView()
    }
  }
}

struct DaydayMarkdownFormatMenu: View {
  let disabled: Bool
  let iconOnly: Bool
  let requestAction: (JournalMarkdownEditorAction) -> Void
  let presentLinkEditor: () -> Void

  var body: some View {
    Menu {
      Menu("标题", systemImage: "textformat.size.larger") {
        ForEach(1...6, id: \.self) { level in
          Button("标题 \(level)") { requestAction(.heading(level)) }
        }
      }
      Button("粗体", systemImage: "bold") { requestAction(.bold) }
        .keyboardShortcut("b", modifiers: .command)
      Button("斜体", systemImage: "italic") { requestAction(.italic) }
        .keyboardShortcut("i", modifiers: .command)
      Button("删除线", systemImage: "strikethrough") { requestAction(.strikethrough) }
      Divider()
      Button("项目列表", systemImage: "list.bullet") { requestAction(.bullet) }
        .keyboardShortcut("u", modifiers: [.command, .option])
      Button("编号列表", systemImage: "list.number") { requestAction(.ordered) }
        .keyboardShortcut("o", modifiers: [.command, .option])
      Button("任务列表", systemImage: "checklist") { requestAction(.task) }
      Button("引用", systemImage: "text.quote") { requestAction(.quote) }
        .keyboardShortcut("q", modifiers: [.command, .option])
      Divider()
      Button("行内代码", systemImage: "chevron.left.forwardslash.chevron.right") {
        requestAction(.inlineCode)
      }
      Button("代码块", systemImage: "curlybraces.square") { requestAction(.codeBlock) }
      Button("链接…", systemImage: "link") { presentLinkEditor() }
        .keyboardShortcut("k", modifiers: .command)
      Button("分隔线", systemImage: "minus") { requestAction(.horizontalRule) }
      Menu("更多格式", systemImage: "ellipsis") {
        Button("表格", systemImage: "tablecells") { requestAction(.table) }
        Button("行内公式", systemImage: "function") { requestAction(.inlineMath) }
        Button("公式块", systemImage: "sum") { requestAction(.mathBlock) }
        Divider()
        Button("减少缩进", systemImage: "decrease.indent") { requestAction(.indentLess) }
        Button("增加缩进", systemImage: "increase.indent") { requestAction(.indentMore) }
        Button("上移当前行", systemImage: "arrow.up") { requestAction(.moveLineUp) }
        Button("下移当前行", systemImage: "arrow.down") { requestAction(.moveLineDown) }
        Button("向上复制当前行", systemImage: "arrow.up.doc") { requestAction(.copyLineUp) }
        Button("向下复制当前行", systemImage: "arrow.down.doc") { requestAction(.copyLineDown) }
      }
    } label: {
      if iconOnly {
        Label("格式", systemImage: DaydayWritingToolbarSymbol.format)
          .labelStyle(.iconOnly)
      } else {
        Label("格式", systemImage: DaydayWritingToolbarSymbol.format)
      }
    }
    .menuStyle(.borderlessButton)
    .disabled(disabled)
    .help(disabled ? "已定稿的日报不可修改" : "段落格式")
  }
}

struct DaydayMarkdownLinkEditor: View {
  @Binding var label: String
  @Binding var destination: String
  let insert: () -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var validationMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("插入链接")
        .font(.title2.weight(.semibold))

      Form {
        TextField("显示文字", text: $label, prompt: Text("链接标题"))
        TextField("网址", text: $destination, prompt: Text("https://example.com"))
      }
      .formStyle(.grouped)

      if let validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("插入") {
          if insert() {
            dismiss()
          } else {
            validationMessage = "请输入有效的 http 或 https 网址"
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 430)
  }
}
