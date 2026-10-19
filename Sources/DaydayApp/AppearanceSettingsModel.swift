import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppearanceSettingsModel: ObservableObject {
  /// The application-wide accent choice. Semantic status colours (success,
  /// warning and failure) deliberately remain independent from this choice.
  enum Accent: String, CaseIterable, Identifiable {
    case systemBlue
    case lavender
    case rose
    case coral

    var id: Self { self }

    var title: String {
      switch self {
      case .systemBlue: "系统蓝"
      case .lavender: "浅紫"
      case .rose: "柔粉"
      case .coral: "珊瑚红"
      }
    }

    var tint: Color {
      switch self {
      case .systemBlue:
        Color(nsColor: .systemBlue)
      case .lavender:
        Color(red: 0.48, green: 0.39, blue: 0.88)
      case .rose:
        Color(red: 0.85, green: 0.34, blue: 0.56)
      case .coral:
        Color(red: 0.88, green: 0.30, blue: 0.27)
      }
    }
  }

  enum Preference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
      switch self {
      case .system: "跟随系统"
      case .light: "浅色"
      case .dark: "深色"
      }
    }

    var colorScheme: ColorScheme? {
      switch self {
      case .system: nil
      case .light: .light
      case .dark: .dark
      }
    }
  }

  static let preferenceKey = "dayday.appearance.preference"
  static let accentKey = "dayday.appearance.accent"

  @Published var preference: Preference {
    didSet { defaults.set(preference.rawValue, forKey: Self.preferenceKey) }
  }

  @Published var accent: Accent {
    didSet { defaults.set(accent.rawValue, forKey: Self.accentKey) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preference = Preference(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    accent = Accent(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .systemBlue
  }
}

private struct DaydayAccentEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppearanceSettingsModel.Accent.systemBlue
}

extension EnvironmentValues {
  var daydayAccent: AppearanceSettingsModel.Accent {
    get { self[DaydayAccentEnvironmentKey.self] }
    set { self[DaydayAccentEnvironmentKey.self] = newValue }
  }
}
