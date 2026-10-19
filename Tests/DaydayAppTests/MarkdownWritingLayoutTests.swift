import Foundation
import Testing

@testable import DaydayApp

@Suite("Shared Markdown writing layout")
struct MarkdownWritingLayoutTests {
  @Test("The editor scrolls at the detail edge while text remains a readable centered column")
  func scrollContainerAndReadableColumnStaySeparate() throws {
    let resourceURL = try #require(
      Bundle.module.url(
        forResource: "dayday-live-preview",
        withExtension: "js",
        subdirectory: "MarkEdit"
      )
    )
    let source = try String(contentsOf: resourceURL, encoding: .utf8)

    #expect(source.contains("'.cm-scroller':"))
    #expect(source.contains("scrollbarWidth: 'thin'"))
    #expect(source.contains("'.cm-scroller::-webkit-scrollbar-thumb':"))
    #expect(source.contains("border: '2px solid transparent'"))
    #expect(source.contains("justifyContent: 'center'"))
    #expect(source.contains("padding: '0 34px'"))
    #expect(source.contains("flex: '0 1 792px'"))
    #expect(source.contains("width: '100%'"))
    #expect(source.contains("maxWidth: '792px'"))
    #expect(source.contains("margin: '0'"))
  }

  @Test("Placeholder and Markdown accents update inside MarkEdit without native text sync")
  func placeholderAndAccentStayOnTheImmediateEditorPath() throws {
    let resourceURL = try #require(
      Bundle.module.url(
        forResource: "dayday-live-preview",
        withExtension: "js",
        subdirectory: "MarkEdit"
      )
    )
    let source = try String(contentsOf: resourceURL, encoding: .utf8)

    #expect(source.contains("const placeholderVisibility = ViewPlugin.fromClass"))
    #expect(source.contains("data-dayday-empty=\"true\""))
    #expect(source.contains("window.daydayJournalSetPlaceholder = placeholder =>"))
    #expect(source.contains("window.daydayJournalSetTheme = theme =>"))
    #expect(source.contains(".cm-editor .cm-md-header:not(.cm-md-quote)"))
    #expect(source.contains(".cm-editor .cm-md-listMark"))
    #expect(source.contains(".cm-editor .cm-md-quoteMark"))
    #expect(source.contains("backgroundColor: 'var(--dayday-scroll-thumb)'"))
  }

  @Test("Geometry-only editor resizing coalesces Live Preview reconstruction")
  func geometryResizeCoalescesLivePreviewReconstruction() throws {
    let resourceURL = try #require(
      Bundle.module.url(
        forResource: "dayday-live-preview",
        withExtension: "js",
        subdirectory: "MarkEdit"
      )
    )
    let source = try String(contentsOf: resourceURL, encoding: .utf8)

    #expect(source.contains("const scheduleGeometryRefresh = view =>"))
    #expect(source.contains("} else if (update.geometryChanged) {"))
    #expect(source.contains("scheduleGeometryRefresh(update.view);"))
    #expect(source.contains("} else if (update.viewportChanged) {"))
  }

  @Test("Writing heatmap hit testing follows week columns and rejects spacing gaps")
  func writingHeatmapHitTesting() throws {
    let layout = DaydayCalendarHeatmapLayout(
      cellSize: 8,
      columnSpacing: 2,
      rowSpacing: 2,
      columnCount: 26,
      rowCount: 7
    )

    #expect(
      DaydayWritingHeatmapGeometry.cellIndex(
        at: CGPoint(x: 1, y: 1),
        layout: layout,
        cellCount: 182
      ) == 0
    )
    #expect(
      DaydayWritingHeatmapGeometry.cellIndex(
        at: CGPoint(x: 11, y: 21),
        layout: layout,
        cellCount: 182
      ) == 9
    )
    #expect(
      DaydayWritingHeatmapGeometry.cellIndex(
        at: CGPoint(x: 9, y: 1),
        layout: layout,
        cellCount: 182
      ) == nil
    )
    #expect(
      DaydayWritingHeatmapGeometry.cellIndex(
        at: CGPoint(x: layout.width, y: 1),
        layout: layout,
        cellCount: 182
      ) == nil
    )
  }

  @Test("Journal review uses one bounded, resizable native inspector column")
  func journalReviewUsesNativeInspectorWidthBounds() {
    #expect(JournalReviewLayoutPolicy.minimumWidth == 280)
    #expect(JournalReviewLayoutPolicy.idealWidth == 320)
    #expect(JournalReviewLayoutPolicy.maximumWidth == 380)
    #expect(JournalReviewLayoutPolicy.minimumWidth < JournalReviewLayoutPolicy.idealWidth)
    #expect(JournalReviewLayoutPolicy.idealWidth < JournalReviewLayoutPolicy.maximumWidth)
  }

  @Test("Only the active retained writing page contributes window toolbar items")
  func retainedWritingToolbarIsScopedToTheActivePage() {
    #expect(DaydayWritingToolbarPresentation.isVisible(isActive: true))
    #expect(!DaydayWritingToolbarPresentation.isVisible(isActive: false))
  }

  @Test("Journal and report share stable macOS writing toolbar symbols")
  func writingToolbarUsesSharedSystemSymbols() {
    #expect(DaydayWritingToolbarSymbol.format == "textformat")
    #expect(DaydayWritingToolbarSymbol.insertImage == "photo.badge.plus")
    #expect(DaydayWritingToolbarSymbol.deleteImage == "trash")
    #expect(DaydayWritingToolbarSymbol.source == "chevron.left.forwardslash.chevron.right")
    #expect(DaydayWritingToolbarSymbol.preview == "doc.richtext")
    #expect(DaydayWritingToolbarSymbol.history == "clock.arrow.circlepath")
    #expect(DaydayWritingToolbarSymbol.export == "square.and.arrow.up")
    #expect(DaydayWritingToolbarSymbol.review == "sidebar.trailing")
    #expect(DaydayWritingToolbarSymbol.saveVersion == "square.and.arrow.down")
    #expect(DaydayWritingToolbarSymbol.finalize == "checkmark.seal")
  }

  @Test("Shared writing review palette follows every global accent choice")
  func journalReviewPaletteUsesSemanticThemeRoles() {
    let environment = DaydayThemeEnvironment(
      appearance: .light,
      contrast: .standard,
      reduceTransparency: false
    )
    let blue = DaydayWritingReviewPalette(
      theme: .mineralCandidate(for: environment, accent: .systemBlue)
    )
    let lavender = DaydayWritingReviewPalette(
      theme: .mineralCandidate(for: environment, accent: .lavender)
    )
    let rose = DaydayWritingReviewPalette(
      theme: .mineralCandidate(for: environment, accent: .rose)
    )
    let coral = DaydayWritingReviewPalette(
      theme: .mineralCandidate(for: environment, accent: .coral)
    )

    #expect(blue.action != lavender.action)
    #expect(lavender.action != rose.action)
    #expect(rose.action != coral.action)
    #expect(coral.action != blue.action)
    #expect(blue.selectionFill != lavender.selectionFill)
    #expect(lavender.selectionBorder == lavender.action)
    #expect(rose.selectionBorder == rose.action)
    #expect(coral.selectionBorder == coral.action)
  }
}
