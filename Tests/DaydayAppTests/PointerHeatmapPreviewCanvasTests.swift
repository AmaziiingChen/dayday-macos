@testable import DaydayApp
import Foundation
import Testing

struct PointerHeatmapPreviewCanvasTests {
  @Test("Built-in display pixels define the preferred preview canvas")
  func prefersBuiltInDisplayPixels() {
    let canvas = PointerHeatmapPreviewCanvas.preferred(from: [
      display(id: 1, pixels: (3_840, 2_160), isMain: true),
      display(id: 2, pixels: (2_560, 1_664), isBuiltIn: true),
    ])

    #expect(canvas?.source == .builtIn)
    #expect(canvas?.pixelWidth == 2_560)
    #expect(canvas?.pixelHeight == 1_664)
    #expect(canvas?.label == "内建显示器 2560 × 1664 像素")
  }

  @Test("Preview canvas uses main display when no built-in panel is available")
  func fallsBackToMainDisplay() {
    let canvas = PointerHeatmapPreviewCanvas.preferred(from: [
      display(id: 1, pixels: (3_840, 2_160)),
      display(id: 2, pixels: (2_560, 1_440), isMain: true),
    ])

    #expect(canvas?.source == .main)
    #expect(canvas?.pixelWidth == 2_560)
    #expect(canvas?.pixelHeight == 1_440)
  }

  @Test("Mirrored or pixel-less displays are not used as a preview reference")
  func ignoresUnusableDisplays() {
    let canvas = PointerHeatmapPreviewCanvas.preferred(from: [
      display(id: 1, pixels: (3_840, 2_160), isBuiltIn: true, isMirrored: true),
      display(id: 2, pixels: nil, isMain: true),
    ])

    #expect(canvas == nil)
  }

  private func display(
    id: UInt32,
    pixels: (Int, Int)?,
    isMain: Bool = false,
    isBuiltIn: Bool = false,
    isMirrored: Bool = false
  ) -> AppRuntimeDisplay {
    AppRuntimeDisplay(
      id: id,
      logicalWidth: 1_280,
      logicalHeight: 832,
      pixelWidth: pixels?.0,
      pixelHeight: pixels?.1,
      rotationDegrees: 0,
      isMain: isMain,
      isBuiltIn: isBuiltIn,
      isMirrored: isMirrored
    )
  }
}
