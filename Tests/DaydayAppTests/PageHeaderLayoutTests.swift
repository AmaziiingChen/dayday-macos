@testable import DaydayApp
import Testing

@Suite("Page header layout")
struct PageHeaderLayoutTests {
  @Test("Actions stay beside the page identity only when both fit")
  func selectsLayoutFromMeasuredContent() {
    #expect(
      AdaptivePairLayoutMode(
        availableWidth: 620,
        leadingWidth: 160,
        trailingWidth: 420,
        spacing: 24
      ) == .horizontal
    )
    #expect(
      AdaptivePairLayoutMode(
        availableWidth: 603,
        leadingWidth: 160,
        trailingWidth: 420,
        spacing: 24
      ) == .stacked
    )
  }

  @Test("A header without actions remains on one row")
  func emptyActionsDoNotForceStacking() {
    #expect(
      AdaptivePairLayoutMode(
        availableWidth: 160,
        leadingWidth: 160,
        trailingWidth: 0,
        spacing: 24
      ) == .horizontal
    )
  }
}
