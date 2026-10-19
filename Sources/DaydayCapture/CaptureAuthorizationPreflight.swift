import ApplicationServices
import CoreGraphics
import Foundation

/// The most precise state that a non-prompting macOS preflight can report.
///
/// macOS preflight APIs do not distinguish an authorization that has never been requested from
/// one that the user denied. Both are represented as ``notAuthorized`` so callers do not imply a
/// certainty the platform did not provide.
public enum CaptureAuthorizationPreflightState: String, Sendable, Equatable {
    case authorized
    case notAuthorized
}

/// A point-in-time, non-prompting view of the two platform permissions needed by later capture
/// slices. Creating this value never means collection has started.
public struct CaptureAuthorizationSnapshot: Sendable, Equatable {
    public let screenRecording: CaptureAuthorizationPreflightState
    public let accessibility: CaptureAuthorizationPreflightState
    public let checkedAt: Date

    public init(
        screenRecording: CaptureAuthorizationPreflightState,
        accessibility: CaptureAuthorizationPreflightState,
        checkedAt: Date
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.checkedAt = checkedAt
    }
}

public protocol CaptureAuthorizationPreflighting: Sendable {
    /// Reads the current authorization state without requesting access or presenting UI.
    func snapshot(at date: Date) -> CaptureAuthorizationSnapshot
}

/// Uses only macOS preflight APIs. It deliberately does not call
/// `CGRequestScreenCaptureAccess` or `AXIsProcessTrustedWithOptions`.
public struct MacOSCaptureAuthorizationPreflight: CaptureAuthorizationPreflighting {
    private let screenRecordingCheck: @Sendable () -> Bool
    private let accessibilityCheck: @Sendable () -> Bool

    public init() {
        self.init(
            screenRecordingCheck: { CGPreflightScreenCaptureAccess() },
            accessibilityCheck: { AXIsProcessTrusted() }
        )
    }

    init(
        screenRecordingCheck: @escaping @Sendable () -> Bool,
        accessibilityCheck: @escaping @Sendable () -> Bool
    ) {
        self.screenRecordingCheck = screenRecordingCheck
        self.accessibilityCheck = accessibilityCheck
    }

    public func snapshot(at date: Date = Date()) -> CaptureAuthorizationSnapshot {
        CaptureAuthorizationSnapshot(
            screenRecording: Self.state(from: screenRecordingCheck()),
            accessibility: Self.state(from: accessibilityCheck()),
            checkedAt: date
        )
    }

    private static func state(from isAuthorized: Bool) -> CaptureAuthorizationPreflightState {
        isAuthorized ? .authorized : .notAuthorized
    }
}
