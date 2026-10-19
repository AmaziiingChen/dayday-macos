import AppKit
import Foundation
import MarkEditCore
import SwiftUI
import Testing
import WebKit

@testable import DaydayApp

@Suite("Packaged Markdown editor resources", .serialized)
struct JournalMarkEditResourceTests {
  @Test("The SwiftPM resource layout renders the real editor template")
  func nestedResourcesRenderEditorConfiguration() throws {
    let html = try JournalMarkEditResources.html(
      configuration: configuration(text: "## 日报\n- 完成接口联调"),
      bundle: .module
    )

    #expect(html.contains("window.config = {"))
    #expect(!html.contains("{{EDITOR_CONFIG}}"))
    #expect(!html.contains("{{USER_SETTINGS}}"))
    #expect(html.contains("chunk-loader://chunks/"))
    #expect(html.contains("完成接口联调"))
    #expect(JournalMarkEditResources.url(for: "dayday-live-preview.js", bundle: .module) != nil)
  }

  @Test("A missing HTML template throws instead of terminating the app")
  func missingTemplateFailsWithoutTrapping() throws {
    let (bundle, root) = try fixtureBundle()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: JournalMarkEditResources.LoadingError.missingTemplate) {
      try JournalMarkEditResources.html(configuration: configuration(), bundle: bundle)
    }
  }

  @Test("A flat Xcode resource layout remains supported")
  func flatResourcesRemainCompatible() throws {
    let (bundle, root) = try fixtureBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    let resourceRoot = try #require(bundle.resourceURL)
    let template = try #require(JournalMarkEditResources.url(for: "index.html", bundle: .module))
    try FileManager.default.copyItem(
      at: template, to: resourceRoot.appendingPathComponent("index.html"))

    let html = try JournalMarkEditResources.html(configuration: configuration(), bundle: bundle)
    #expect(html.contains("window.config = {"))
    #expect(!html.contains("{{EDITOR_CONFIG}}"))
  }

  @Test("An unreadable template reports an error instead of loading an empty document")
  func invalidTemplateEncodingFails() throws {
    let (bundle, root) = try fixtureBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    let resourceRoot = try #require(bundle.resourceURL)
    try Data([0xFF, 0xFE, 0xFF]).write(to: resourceRoot.appendingPathComponent("index.html"))

    #expect(throws: (any Error).self) {
      try JournalMarkEditResources.html(configuration: configuration(), bundle: bundle)
    }
  }

  @MainActor
  @Test(
    "Report and journal initialize the actual WebKit editor without a visible window",
    arguments: ["日报", "日记"])
  func writingPagesInitializeOffscreen(label: String) async throws {
    _ = NSApplication.shared
    var state = JournalMarkEditState.loading
    let theme = DaydayTheme.mineralCandidate(
      for: .init(appearance: .light, contrast: .standard, reduceTransparency: false),
      accent: .systemBlue
    )
    let editor = JournalMarkEditEditor(
      markdown: .constant("## \(label)\n- 离线编辑器验证"),
      placeholder: "开始记录",
      editorTheme: .init(theme: theme, increasedContrast: false),
      imageResources: [:],
      pendingAttachment: nil,
      attachmentRequest: 0,
      action: nil,
      actionRequest: 0,
      snapshotRequest: 0,
      reloadRequest: 0,
      isSourceMode: false,
      isReadOnly: false,
      isActive: true,
      accessibilityLabel: label,
      onStateChange: { state = $0 },
      onSelectionChange: { _ in },
      onRequestAttachmentRemoval: { _ in },
      onUserEdit: {},
      onSnapshot: { _, _ in }
    )
    let resourceBundle: Bundle
    if let appPath = ProcessInfo.processInfo.environment["DAYDAY_EDITOR_TEST_APP_BUNDLE"] {
      resourceBundle = try #require(Bundle(url: URL(fileURLWithPath: appPath)))
    } else {
      resourceBundle = .module
    }
    let coordinator = JournalMarkEditEditor.Coordinator(
      parent: editor, resourceBundle: resourceBundle)
    let host = JournalMarkEditHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    coordinator.install(in: host)
    #expect(host.window == nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while state == .loading && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    #expect(state == .ready)
    let webView = try #require(host.subviews.first as? WKWebView)
    let text = try await webView.evaluateJavaScript("window.editor.state.doc.toString()") as? String
    #expect(text == "## \(label)\n- 离线编辑器验证")
    withExtendedLifetime(coordinator) {}
  }

  private func fixtureBundle() throws -> (Bundle, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundleURL = root.appendingPathComponent("EditorFixture.bundle")
    try FileManager.default.createDirectory(
      at: bundleURL.appendingPathComponent("Contents/Resources"),
      withIntermediateDirectories: true
    )
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "app.dayday.tests.editor.\(UUID().uuidString)"],
      format: .xml,
      options: 0
    )
    try info.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    return (try #require(Bundle(url: bundleURL)), root)
  }

  private func configuration(text: String = "") -> EditorConfig {
    EditorConfig(
      text: text,
      theme: "github-light",
      fontFace: .init(family: "-apple-system", weight: nil, style: nil),
      fontSize: 18,
      showLineNumbers: false,
      showActiveLineIndicator: false,
      invisiblesBehavior: .never,
      readOnlyMode: false,
      typewriterMode: false,
      focusMode: false,
      lineWrapping: true,
      lineHeight: 1.62,
      suggestWhileTyping: false,
      defaultLineBreak: "\n",
      tabKeyBehavior: 3,
      indentUnit: "    ",
      localizable: nil,
      autoCharacterPairs: true,
      indentBehavior: .paragraph,
      headerFontSizeDiffs: nil,
      visibleWhitespaceCharacter: nil,
      visibleLineBreakCharacter: nil,
      searchNormalizers: nil
    )
  }
}
