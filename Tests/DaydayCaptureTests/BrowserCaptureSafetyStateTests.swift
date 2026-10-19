import Foundation
import Testing

@testable import DaydayCapture

struct BrowserCaptureSafetyStateTests {
  @Test
  func freshOrdinaryChromeAndTabbitStatesPermitCapture() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    for bundle in ["com.google.chrome", "com.tab-browser.tabbit"] {
      try write(
        BrowserCaptureSafetyState(
          protocolVersion: 1, browserBundleIdentifier: bundle, sequence: 1,
          bridgeReady: true, incognito: false, observedAt: now),
        to: directory
      )
      let store = BrowserCaptureSafetyStateStore(directory: directory, clock: { now })
      #expect(store.permitsCapture(bundleIdentifier: bundle))
    }
  }

  @Test
  func incognitoStaleWrongBrowserAndUnreadyStatesFailClosed() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let store = BrowserCaptureSafetyStateStore(directory: directory, clock: { now })

    try write(
      BrowserCaptureSafetyState(
        protocolVersion: 1, browserBundleIdentifier: "com.google.chrome", sequence: 1,
        bridgeReady: true, incognito: true, observedAt: now),
      to: directory
    )
    #expect(!store.permitsCapture(bundleIdentifier: "com.google.chrome"))

    try write(
      BrowserCaptureSafetyState(
        protocolVersion: 1, browserBundleIdentifier: "com.google.chrome", sequence: 2,
        bridgeReady: true, incognito: false, observedAt: now.addingTimeInterval(-46)),
      to: directory
    )
    #expect(!store.permitsCapture(bundleIdentifier: "com.google.chrome"))
    #expect(!store.permitsCapture(bundleIdentifier: "com.tab-browser.tabbit"))

    try write(
      BrowserCaptureSafetyState(
        protocolVersion: 1, browserBundleIdentifier: "com.google.chrome", sequence: 3,
        bridgeReady: false, incognito: false, observedAt: now),
      to: directory
    )
    #expect(!store.permitsCapture(bundleIdentifier: "com.google.chrome"))
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayday-browser-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ state: BrowserCaptureSafetyState, to directory: URL) throws {
    let url = directory.appendingPathComponent("\(state.browserBundleIdentifier).json")
    try JSONEncoder().encode(state).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
