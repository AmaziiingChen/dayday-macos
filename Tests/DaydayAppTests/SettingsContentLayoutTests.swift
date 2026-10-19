@testable import DaydayApp
import Testing

@Suite("Settings content layout")
struct SettingsContentLayoutTests {
  @Test("Secondary navigation follows the available detail width, not preview text")
  func selectsByAvailableWidth() {
    let breakpoint = SettingsContentLayout.minimumRegularWidth

    #expect(SettingsContentLayout(availableWidth: 0) == .compact)
    #expect(SettingsContentLayout(availableWidth: breakpoint - 1) == .compact)
    #expect(SettingsContentLayout(availableWidth: breakpoint) == .regular)
    #expect(SettingsContentLayout(availableWidth: breakpoint + 500) == .regular)
  }

  @Test("Secondary navigation yields to the content column before it can overflow")
  func collapsesAtNarrowDetailWidths() {
    #expect(SettingsContentLayout.minimumRegularWidth >= 860)
    #expect(SettingsContentLayout(availableWidth: 859) == .compact)
  }
}
