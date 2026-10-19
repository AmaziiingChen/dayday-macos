import AppKit
import Testing

@testable import DaydayApp

@MainActor
struct DaydayApplicationDelegateTests {
  @Test("Closing the final main window preserves the menu-bar application")
  func closingLastWindowDoesNotTerminateDayday() {
    let delegate = DaydayApplicationDelegate()

    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
  }
}
