import Foundation
import Testing
@testable import DaydayCapture

struct CaptureAuthorizationPreflightTests {
    @Test
    func mapsIndependentChecksWithoutPromptingOrChangingTimestamp() {
        let checkedAt = Date(timeIntervalSince1970: 1_754_000_000)
        let preflight = MacOSCaptureAuthorizationPreflight(
            screenRecordingCheck: { true },
            accessibilityCheck: { false }
        )

        let snapshot = preflight.snapshot(at: checkedAt)

        #expect(snapshot == CaptureAuthorizationSnapshot(
            screenRecording: .authorized,
            accessibility: .notAuthorized,
            checkedAt: checkedAt
        ))
    }

    @Test
    func reportsOnlyThePrecisionAvailableFromMacOSPreflight() {
        let preflight = MacOSCaptureAuthorizationPreflight(
            screenRecordingCheck: { false },
            accessibilityCheck: { false }
        )

        let snapshot = preflight.snapshot(at: .distantPast)

        #expect(snapshot.screenRecording == .notAuthorized)
        #expect(snapshot.accessibility == .notAuthorized)
    }
}
