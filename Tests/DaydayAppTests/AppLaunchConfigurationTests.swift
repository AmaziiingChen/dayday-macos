import Foundation
import Testing

struct AppLaunchConfigurationTests {
  @Test("LaunchServices rejects a second production Dayday before application composition")
  func productionBundleProhibitsMultipleInstances() throws {
    let sourceFile = URL(fileURLWithPath: #filePath)

    let projectRoot =
      sourceFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let infoPlistURL = projectRoot.appendingPathComponent("Config/Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    )

    #expect(plist["LSMultipleInstancesProhibited"] as? Bool == true)
  }

  @Test("UI acceptance launcher uses a separate identity and user-domain data root")
  func uiAcceptanceLauncherIsIsolated() throws {
    let sourceFile = URL(fileURLWithPath: #filePath)

    let projectRoot =
      sourceFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let launcherURL = projectRoot.appendingPathComponent("scripts/run-ui-acceptance.sh")
    let launcher = try String(contentsOf: launcherURL, encoding: .utf8)

    #expect(launcher.contains("app.dayday.local.ui-acceptance"))
    #expect(launcher.contains("CFFIXED_USER_HOME=$acceptance_home"))
    #expect(launcher.contains("dayday-ui-acceptance.XXXXXX"))
    #expect(!launcher.contains("source \"$environment_file\""))
  }
}
