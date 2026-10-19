import Darwin
import Foundation

struct BrowserCaptureSafetyState: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let browserBundleIdentifier: String
  let sequence: UInt64
  let bridgeReady: Bool
  let incognito: Bool
  let observedAt: Date
}

/// Reads only the short-lived allow/deny capability written by the native host. Browser title and
/// URL fields are deliberately not decoded here, so Capture cannot accidentally persist them.
struct BrowserCaptureSafetyStateStore: Sendable {
  private let directory: URL
  private let clock: @Sendable () -> Date
  private let maximumAge: TimeInterval

  init(
    directory: URL? = nil,
    clock: @escaping @Sendable () -> Date = Date.init,
    maximumAge: TimeInterval = 45
  ) {
    if let directory {
      self.directory = directory
    } else {
      self.directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0]
      .appendingPathComponent("Dayday", isDirectory: true)
      .appendingPathComponent("BrowserBridge", isDirectory: true)
    }
    self.clock = clock
    self.maximumAge = maximumAge
  }

  func permitsCapture(bundleIdentifier: String) -> Bool {
    let normalized = bundleIdentifier.lowercased()
    guard Self.supportedBundleIdentifiers.contains(normalized), maximumAge > 0 else { return false }
    let url = directory.appendingPathComponent("\(normalized).json")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let permissions = attributes[.posixPermissions] as? NSNumber,
      let owner = attributes[.ownerAccountID] as? NSNumber,
      attributes[.type] as? FileAttributeType == .typeRegular,
      owner.uint32Value == getuid(),
      permissions.intValue & 0o077 == 0,
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.count <= 4_096,
      let state = try? JSONDecoder().decode(BrowserCaptureSafetyState.self, from: data),
      state.protocolVersion == 1,
      state.browserBundleIdentifier == normalized,
      state.bridgeReady,
      !state.incognito
    else { return false }
    let age = clock().timeIntervalSince(state.observedAt)
    return age >= 0 && age <= maximumAge
  }

  static let supportedBundleIdentifiers: Set<String> = [
    "com.google.chrome",
    "com.google.chrome.beta",
    "com.google.chrome.canary",
    "org.chromium.chromium",
    "com.tab-browser.tabbit",
  ]
}
