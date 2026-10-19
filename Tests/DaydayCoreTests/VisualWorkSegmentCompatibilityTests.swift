import DaydayCore
import Foundation
import Testing

struct VisualWorkSegmentCompatibilityTests {
  @Test
  func decodesPreAgreementRecordsAsUnavailable() throws {
    let display = DisplayID()
    let legacy = """
    {"primarySituation":"阅读文档","interaction":"页面稳定","activityKind":"reading","foregroundApplicationLabel":"Safari","displays":[{"displayID":{"rawValue":"\(display.rawValue.uuidString)"},"role":"primary","visibleState":"文档"}],"relationship":"coordinated","confidence":0.8,"evidence":["文档可见"],"uncertainties":[],"recordVersion":1}
    """
    let decoded = try JSONDecoder().decode(VisualWorkSegment.self, from: Data(legacy.utf8))
    #expect(decoded.systemContextAgreement == .unavailable)
  }
}
