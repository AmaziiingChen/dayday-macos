import Foundation
import SwiftUI
import Testing

@testable import DaydayApp

@Suite("Appearance settings")
@MainActor
struct AppearanceSettingsModelTests {
  @Test
  func defaultsToSystemAppearance() {
    let model = AppearanceSettingsModel(defaults: makeDefaults())

    #expect(model.preference == .system)
    #expect(model.preference.colorScheme == nil)
  }

  @Test
  func persistsAnExplicitAppearanceAndRestoresIt() {
    let defaults = makeDefaults()
    let model = AppearanceSettingsModel(defaults: defaults)
    model.preference = .dark

    #expect(defaults.string(forKey: AppearanceSettingsModel.preferenceKey) == "dark")
    #expect(model.preference.colorScheme == .dark)
    #expect(AppearanceSettingsModel(defaults: defaults).preference == .dark)
  }

  @Test
  func persistsAccentChoiceIndependentlyFromAppearance() {
    let defaults = makeDefaults()
    let model = AppearanceSettingsModel(defaults: defaults)
    model.accent = .lavender

    #expect(defaults.string(forKey: AppearanceSettingsModel.accentKey) == "lavender")
    #expect(AppearanceSettingsModel(defaults: defaults).accent == .lavender)
  }

  @Test
  func fallsBackToSystemBlueForAnUnknownPersistedAccent() {
    let defaults = makeDefaults()
    defaults.set("neon", forKey: AppearanceSettingsModel.accentKey)

    #expect(AppearanceSettingsModel(defaults: defaults).accent == .systemBlue)
  }

  @Test
  func fallsBackToSystemForAnUnknownPersistedAppearance() {
    let defaults = makeDefaults()
    defaults.set("contrast", forKey: AppearanceSettingsModel.preferenceKey)

    #expect(AppearanceSettingsModel(defaults: defaults).preference == .system)
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "AppearanceSettingsModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
