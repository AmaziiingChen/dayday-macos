import Testing

@testable import DaydayApp

@Suite("Today content layout")
struct TodayContentLayoutTests {
  @Test("The layout breakpoint depends only on the available content width")
  func availableWidthSelectsLayout() {
    let breakpoint = TodayContentLayout.minimumTwoColumnContentWidth

    #expect(TodayContentLayout(availableWidth: 0) == .stacked)
    #expect(TodayContentLayout(availableWidth: breakpoint - 1) == .stacked)
    #expect(TodayContentLayout(availableWidth: breakpoint) == .twoColumn)
    #expect(TodayContentLayout(availableWidth: breakpoint + 400) == .twoColumn)
  }
}
