import Testing

@testable import DaydayApp

@Suite("Menu bar application duration bars")
struct MenuBarApplicationBarLayoutTests {
  @Test("Duration column reserves enough width for a single-line Chinese duration")
  func durationColumnKeepsCommonHourDurationsOnOneLine() {
    #expect(MenuBarApplicationBarLayout.durationColumnWidth >= 68)
  }

  @Test("Bar fractions remain finite and inside the drawable range")
  func normalizedFractionsAreClamped() {
    #expect(MenuBarApplicationBarLayout.normalizedFraction(duration: 30, maximum: 120) == 0.25)
    #expect(MenuBarApplicationBarLayout.normalizedFraction(duration: 180, maximum: 120) == 1)
    #expect(MenuBarApplicationBarLayout.normalizedFraction(duration: -1, maximum: 120) == 0)
    #expect(MenuBarApplicationBarLayout.normalizedFraction(duration: 30, maximum: 0) == 0)
    #expect(
      MenuBarApplicationBarLayout.normalizedFraction(
        duration: .infinity,
        maximum: 120
      ) == 0
    )
  }
}
