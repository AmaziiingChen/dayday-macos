@testable import DaydayApp
import Testing

struct KeyboardPhysicalLayoutProfileTests {
  @Test("MacBook-shaped built-in display selects the laptop keyboard layout")
  func selectsMacBookLayout() {
    let profile = KeyboardPhysicalLayoutProfile.preferred(from: [
      display(id: 1, pixels: (2_560, 1_664), isBuiltIn: true),
      display(id: 2, pixels: (3_840, 2_160), isMain: true),
    ])

    #expect(profile == .macBook)
    #expect(profile.showsTouchID)
  }

  @Test("Desktop or unavailable built-in display keeps the generic fallback")
  func keepsGenericFallback() {
    #expect(KeyboardPhysicalLayoutProfile.preferred(from: [
      display(id: 1, pixels: (4_480, 2_520), isBuiltIn: true),
    ]) == .externalANSI)
    #expect(KeyboardPhysicalLayoutProfile.preferred(from: [
      display(id: 1, pixels: (2_560, 1_664), isBuiltIn: true, isMirrored: true),
    ]) == .externalANSI)
  }

  private func display(
    id: UInt32,
    pixels: (Int, Int),
    isMain: Bool = false,
    isBuiltIn: Bool = false,
    isMirrored: Bool = false
  ) -> AppRuntimeDisplay {
    AppRuntimeDisplay(
      id: id,
      logicalWidth: Double(pixels.0) / 2,
      logicalHeight: Double(pixels.1) / 2,
      pixelWidth: pixels.0,
      pixelHeight: pixels.1,
      rotationDegrees: 0,
      isMain: isMain,
      isBuiltIn: isBuiltIn,
      isMirrored: isMirrored
    )
  }
}
