@testable import DaydayApp
import CoreGraphics
import Testing

@Suite("Dayday scroll indicators and editor accents")
struct DaydayScrollIndicatorTests {
  @Test("Scroll thumbs keep a thin edge-aligned visual inside the native hit target")
  func thumbGeometry() {
    let vertical = DaydayScrollIndicatorMetrics.visualKnobRect(
      in: CGRect(x: 0, y: 20, width: 15, height: 120),
      isVertical: true,
      increasedContrast: false
    )
    #expect(vertical == CGRect(x: 8, y: 20, width: 4, height: 120))

    let accessibleVertical = DaydayScrollIndicatorMetrics.visualKnobRect(
      in: CGRect(x: 0, y: 20, width: 15, height: 120),
      isVertical: true,
      increasedContrast: true
    )
    #expect(accessibleVertical == CGRect(x: 7, y: 20, width: 5, height: 120))

    let horizontal = DaydayScrollIndicatorMetrics.visualKnobRect(
      in: CGRect(x: 20, y: 0, width: 120, height: 15),
      isVertical: false,
      increasedContrast: false
    )
    #expect(horizontal == CGRect(x: 20, y: 3, width: 120, height: 4))
  }

  @Test("Markdown chrome follows the selected accent in light and dark appearances")
  func markdownChromeUsesSemanticAccent() {
    let lightEnvironment = DaydayThemeEnvironment(
      appearance: .light,
      contrast: .standard,
      reduceTransparency: false
    )
    let darkEnvironment = DaydayThemeEnvironment(
      appearance: .dark,
      contrast: .standard,
      reduceTransparency: false
    )
    let light = DaydayMarkdownEditorTheme(
      theme: .mineralCandidate(for: lightEnvironment, accent: .lavender),
      increasedContrast: false
    )
    let dark = DaydayMarkdownEditorTheme(
      theme: .mineralCandidate(for: darkEnvironment, accent: .lavender),
      increasedContrast: false
    )

    #expect(light.accent == "rgba(122, 99, 224, 1.000)")
    #expect(dark.accent == "rgba(163, 145, 255, 1.000)")
    #expect(light.scrollThumb == "rgba(122, 99, 224, 0.280)")
    #expect(light.accent != dark.accent)
  }
}
