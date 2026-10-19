import AppKit
@preconcurrency import ApplicationServices
import Carbon
@preconcurrency import CoreVideo
import DaydayCore
import Foundation
@preconcurrency import ImageIO
import OSLog
import UniformTypeIdentifiers
@preconcurrency import Vision

private let screenUnderstandingLogger = Logger(
  subsystem: "app.dayday.local",
  category: "screen-understanding"
)

/// Bounded, redaction-passed text observed on one ephemeral screen frame.
///
/// The value deliberately contains no pixels, image location, Vision object, or Activity
/// interpretation. Empty `lines` means OCR found text but every line was suppressed by the
/// credential redactor.
public struct ObjectiveScreenTextObservation: Sendable, Equatable {
  public enum ValidationError: Error, Equatable, Sendable {
    case tooManyLines(Int)
    case emptyWithoutRedaction
  }

  public let frame: ObjectiveScreenFrameMetadata
  public let lines: [RedactedOCRLine]
  public let redactionApplied: Bool

  public init(
    frame: ObjectiveScreenFrameMetadata,
    lines: [RedactedOCRLine],
    redactionApplied: Bool
  ) throws {
    guard lines.count <= OCRArtifact.maximumLineCount else {
      throw ValidationError.tooManyLines(lines.count)
    }
    guard !lines.isEmpty || redactionApplied else {
      throw ValidationError.emptyWithoutRedaction
    }
    self.frame = frame
    self.lines = lines
    self.redactionApplied = redactionApplied
  }
}

struct EphemeralFrameAnalysis: Sendable, Equatable {
  let lines: [RedactedOCRLine]
  let redactionApplied: Bool
  let visionDerivative: PreparedScreenVisionDerivative?
}

struct ScreenTextRecognition: Sendable, Equatable {
  let text: String
  /// Vision-normalized coordinates with an origin at the lower-left.
  let normalizedBoundingBox: CGRect

  init(text: String, normalizedBoundingBox: CGRect = .zero) {
    self.text = text
    self.normalizedBoundingBox = normalizedBoundingBox
  }
}

protocol ScreenTextRecognizing: Sendable {
  func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition]
  func attemptRecognition(in pixelBuffer: CVPixelBuffer) throws -> ScreenTextRecognitionAttempt
  func cancelPendingRecognition()
}

extension ScreenTextRecognizing {
  func attemptRecognition(in pixelBuffer: CVPixelBuffer) throws -> ScreenTextRecognitionAttempt {
    .completed(try recognizeText(in: pixelBuffer))
  }

  func cancelPendingRecognition() {}
}

enum ScreenTextRecognitionAttempt: Sendable {
  case completed([ScreenTextRecognition])
  /// Another display already owns the process-wide Vision lane. The caller must retain its
  /// cadence/anchor eligibility so a newer frame can retry instead of waiting behind stale pixels.
  case deferred
}

/// A nonblocking, process-wide lane for expensive local OCR work.
///
/// Each display keeps its own latest-frame pump, but only the display that acquires this lane may
/// enter Apple Vision. Losers return immediately, allowing their pump's replaceable pending slot
/// to retain the freshest frame instead of building a cross-display queue.
final class ScreenOCRExecutionCoordinator: @unchecked Sendable {
  static let shared = ScreenOCRExecutionCoordinator()

  private let lock = NSLock()
  private var isOccupied = false

  func tryAcquire() -> ScreenOCRExecutionLease? {
    lock.withLock {
      guard !isOccupied else { return nil }
      isOccupied = true
      return ScreenOCRExecutionLease { [self] in
        lock.withLock { isOccupied = false }
      }
    }
  }
}

final class ScreenOCRExecutionLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseHandler: (@Sendable () -> Void)?

  init(releaseHandler: @escaping @Sendable () -> Void) {
    self.releaseHandler = releaseHandler
  }

  func release() {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      defer { releaseHandler = nil }
      return releaseHandler
    }
    handler?()
  }

  deinit {
    release()
  }
}

protocol ScreenOCRSafetyEvaluating: Sendable {
  func permitsOCR() -> Bool
}

struct MacOSScreenOCRSafetyGate: ScreenOCRSafetyEvaluating {
  private enum FocusedElementLookup {
    case present(AXUIElement)
    case absent
    case unavailable
  }

  private enum AttributeStringLookup {
    case present(String)
    case absent
    case unavailable
  }

  private static let excludedApplicationNames = [
    "1password", "bitwarden", "dashlane", "lastpass", "keychain access", "passwords",
    "loginwindow", "securityagent",
  ]

  private let browserSafety = BrowserCaptureSafetyStateStore()

  func permitsOCR() -> Bool {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return false }
    let system = AXUIElementCreateSystemWide()
    guard
      let application = Self.element(
        kAXFocusedApplicationAttribute as CFString,
        from: system
      ), let applicationName = Self.string(kAXTitleAttribute as CFString, from: application)
    else { return false }
    var processIdentifier: pid_t = 0
    guard AXUIElementGetPid(application, &processIdentifier) == .success else { return false }
    let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?
      .bundleIdentifier?.lowercased()
    if let bundleIdentifier,
      BrowserCaptureSafetyStateStore.supportedBundleIdentifiers.contains(bundleIdentifier)
    {
      guard browserSafety.permitsCapture(bundleIdentifier: bundleIdentifier) else { return false }
    }
    let normalizedApplicationName = applicationName.lowercased()
    guard !Self.excludedApplicationNames.contains(where: normalizedApplicationName.contains)
    else { return false }

    // A normal reading surface often has no focused accessibility element at all. That is not a
    // sensitive state: the application and browser gates above still identify the foreground
    // source, while secure-input mode remains the hard boundary. Treat only an explicitly
    // sensitive focused role as a denial so ordinary, non-editable windows can be understood.
    switch Self.focusedElement(from: application) {
    case .present(let focusedElement):
      guard
        case .present(let role) = Self.attributeString(
          kAXRoleAttribute as CFString,
          from: focusedElement
        )
      else { return false }
      let subrole: String?
      switch Self.attributeString(kAXSubroleAttribute as CFString, from: focusedElement) {
      case .present(let value):
        subrole = value
      case .absent:
        subrole = nil
      case .unavailable:
        return false
      }
      return Self.permitsFocusedElement(role: role, subrole: subrole)
    case .absent:
      return true
    case .unavailable:
      return false
    }
  }

  private static func element(_ attribute: CFString, from source: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func string(_ attribute: CFString, from source: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success else { return nil }
    return value as? String
  }

  private static func focusedElement(from application: AXUIElement) -> FocusedElementLookup {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      application,
      kAXFocusedUIElementAttribute as CFString,
      &value
    )
    switch status {
    case .success:
      guard let value else { return .absent }
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
      return .present(unsafeDowncast(value, to: AXUIElement.self))
    case .noValue, .attributeUnsupported:
      return .absent
    default:
      return .unavailable
    }
  }

  private static func attributeString(
    _ attribute: CFString,
    from source: AXUIElement
  ) -> AttributeStringLookup {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(source, attribute, &value)
    switch status {
    case .success:
      guard let value else { return .absent }
      guard let string = value as? String else { return .unavailable }
      return .present(string)
    case .noValue, .attributeUnsupported:
      return .absent
    default:
      return .unavailable
    }
  }

  private static func isSensitiveRole(_ role: String) -> Bool {
    let normalized = role.lowercased()
    return normalized.contains("password")
      || normalized.contains("secure")
      || normalized.contains("authentication")
      || normalized.contains("login")
  }

  static func permitsFocusedElement(role: String?, subrole: String?) -> Bool {
    ![role, subrole].compactMap { $0 }.contains(where: isSensitiveRole)
  }
}

final class AppleVisionScreenTextRecognizer: ScreenTextRecognizing, @unchecked Sendable {
  private let executionCoordinator: ScreenOCRExecutionCoordinator
  private let requestLock = NSLock()
  private var activeRequest: VNRecognizeTextRequest?

  init(executionCoordinator: ScreenOCRExecutionCoordinator = .shared) {
    self.executionCoordinator = executionCoordinator
  }

  func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition] {
    guard let lease = executionCoordinator.tryAcquire() else {
      throw ScreenOCRExecutionError.temporarilyUnavailable
    }
    defer { lease.release() }
    return try performRecognition(in: pixelBuffer)
  }

  func attemptRecognition(in pixelBuffer: CVPixelBuffer) throws -> ScreenTextRecognitionAttempt {
    guard let lease = executionCoordinator.tryAcquire() else { return .deferred }
    defer { lease.release() }
    return .completed(try performRecognition(in: pixelBuffer))
  }

  private func performRecognition(in pixelBuffer: CVPixelBuffer) throws
    -> [ScreenTextRecognition]
  {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]

    requestLock.withLock { activeRequest = request }
    defer {
      requestLock.withLock {
        if activeRequest === request { activeRequest = nil }
      }
    }

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    try handler.perform([request])
    return request.results?.compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string else { return nil }
      return ScreenTextRecognition(text: text, normalizedBoundingBox: observation.boundingBox)
    } ?? []
  }

  /// Vision recognition is CPU intensive and may still be running after ScreenCaptureKit stops.
  /// Cancellation is safe from the application/lifecycle thread and never exposes frame content.
  func cancelPendingRecognition() {
    let request = requestLock.withLock { activeRequest }
    request?.cancel()
  }
}

private enum ScreenOCRExecutionError: Error {
  case temporarilyUnavailable
}

struct PreparedScreenVisionDerivative: Sendable, Equatable {
  let encodedJPEG: Data
  let pixelWidth: Int
  let pixelHeight: Int
}

/// Serial processor used only by `EphemeralFramePump`'s private utility queue.
/// Mutable state is safe because the pump invokes this value synchronously and never concurrently.
final class LocalScreenOCRProcessor: @unchecked Sendable {
  private struct DisplayState {
    var lastCadenceAt: Date?
    var lastAnchorAttemptAt: Date?
    var ordinaryInterval: TimeInterval?
    var lastObservedFingerprint: ScreenFrameFingerprint?
  }

  private struct ClaimedAnchor {
    let generation: UInt64
  }

  private let recognizer: any ScreenTextRecognizing
  private let safetyGate: any ScreenOCRSafetyEvaluating
  private let minimumInterval: TimeInterval
  private let maximumInterval: TimeInterval
  private let anchorCooldown: TimeInterval
  /// Anchor requests may arrive from the stream actor while processing happens on the frame-pump
  /// queue. They deliberately carry no input event data: the only effect is to let the next safe
  /// frame bypass the normal cadence check once.
  private let anchorLock = NSLock()
  private var anchorGeneration: UInt64 = 0
  private var pendingAnchorGeneration: UInt64?
  private var states: [DisplayID: DisplayState] = [:]

  init(
    recognizer: any ScreenTextRecognizing = AppleVisionScreenTextRecognizer(),
    safetyGate: any ScreenOCRSafetyEvaluating = MacOSScreenOCRSafetyGate(),
    minimumInterval: TimeInterval = 60,
    maximumInterval: TimeInterval = 300,
    anchorCooldown: TimeInterval = 5
  ) {
    precondition(minimumInterval >= 0 && minimumInterval.isFinite)
    precondition(maximumInterval >= minimumInterval && maximumInterval.isFinite)
    precondition(anchorCooldown >= 0 && anchorCooldown.isFinite)
    self.recognizer = recognizer
    self.safetyGate = safetyGate
    self.minimumInterval = minimumInterval
    self.maximumInterval = maximumInterval
    self.anchorCooldown = anchorCooldown
  }

  /// Coalesces a context/submission request into the next frame processing opportunity. The
  /// subsequent frame still passes all safety, redaction, fingerprint, and size checks.
  func requestImmediateProcessing() {
    anchorLock.withLock {
      anchorGeneration &+= 1
      pendingAnchorGeneration = anchorGeneration
    }
  }

  /// Clears a queued anchor and asks the platform recognizer to stop any in-flight request. The
  /// frame pump still owns disposal of the volatile pixel buffer after `process` returns.
  func cancelPendingProcessing() {
    anchorLock.withLock {
      anchorGeneration &+= 1
      pendingAnchorGeneration = nil
    }
    recognizer.cancelPendingRecognition()
  }

  func process(_ frame: EphemeralScreenFrame) -> EphemeralFrameAnalysis? {
    let state = states[frame.metadata.display.id] ?? DisplayState()
    let claimedAnchor = claimAnchorIfReady(at: frame.metadata.observedAt, state: state)
    let isAnchored = claimedAnchor != nil
    let ordinaryInterval = state.ordinaryInterval ?? minimumInterval
    if !isAnchored, let lastCadenceAt = state.lastCadenceAt,
      frame.metadata.observedAt.timeIntervalSince(lastCadenceAt) >= 0,
      frame.metadata.observedAt.timeIntervalSince(lastCadenceAt) < ordinaryInterval
    {
      return nil
    }
    guard safetyGate.permitsOCR() else {
      recordAttempt(
        for: frame.metadata.display.id,
        at: frame.metadata.observedAt,
        claimedAnchor: claimedAnchor
      )
      screenUnderstandingLogger.notice("OCR attempt denied by the local safety gate")
      return nil
    }

    return frame.withPixelBuffer { [self] pixelBuffer in
      autoreleasepool {
        let fingerprint = Self.fingerprint(pixelBuffer)
        if let fingerprint, let previous = state.lastObservedFingerprint,
          !fingerprint.isSignificantlyDifferent(from: previous)
        {
          recordStableObservation(
            for: frame.metadata.display.id,
            at: frame.metadata.observedAt,
            fingerprint: fingerprint,
            claimedAnchor: claimedAnchor
          )
          return nil
        }

        let recognitions: [ScreenTextRecognition]
        do {
          switch try recognizer.attemptRecognition(in: pixelBuffer) {
          case .completed(let completedRecognitions):
            recognitions = completedRecognitions
          case .deferred:
            restore(claimedAnchor)
            screenUnderstandingLogger.debug(
              "Local Vision OCR deferred while another display owns the global lane"
            )
            return nil
          }
        } catch {
          recordSignificantAttempt(
            for: frame.metadata.display.id,
            at: frame.metadata.observedAt,
            claimedAnchor: claimedAnchor
          )
          screenUnderstandingLogger.error("Local Vision OCR failed")
          return nil
        }
        recordSignificantAttempt(
          for: frame.metadata.display.id,
          at: frame.metadata.observedAt,
          fingerprint: fingerprint,
          claimedAnchor: claimedAnchor
        )
        let redacted = ScreenCredentialRedactor.redact(recognitions)
        let derivative = ScreenVisionDerivativeEncoder.encode(
          pixelBuffer,
          redacting: redacted.sensitiveBounds
        )
        if derivative == nil {
          screenUnderstandingLogger.error(
            "Visual derivative encoding failed for pixel format \(CVPixelBufferGetPixelFormatType(pixelBuffer), privacy: .public) at \(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public)"
          )
        }
        if recognitions.isEmpty {
          screenUnderstandingLogger.notice(
            "Local Vision OCR found no text; retaining only the redacted visual derivative"
          )
        } else {
          screenUnderstandingLogger.notice(
            "Local Vision OCR produced a bounded redacted observation"
          )
        }
        return EphemeralFrameAnalysis(
          lines: redacted.lines,
          redactionApplied: redacted.didRemoveContent,
          visionDerivative: derivative
        )
      }
    } ?? nil
  }

  private func claimAnchorIfReady(at date: Date, state: DisplayState) -> ClaimedAnchor? {
    anchorLock.withLock {
      guard let generation = pendingAnchorGeneration else { return nil }
      if let lastAnchorAttemptAt = state.lastAnchorAttemptAt {
        let elapsed = date.timeIntervalSince(lastAnchorAttemptAt)
        if elapsed >= 0, elapsed < anchorCooldown { return nil }
      }
      pendingAnchorGeneration = nil
      return ClaimedAnchor(generation: generation)
    }
  }

  private func restore(_ claimedAnchor: ClaimedAnchor?) {
    guard let claimedAnchor else { return }
    anchorLock.withLock {
      // A newer request already represents this work. A cancellation advances the generation and
      // deliberately prevents an in-flight loser from resurrecting the cleared anchor.
      guard anchorGeneration == claimedAnchor.generation else { return }
      pendingAnchorGeneration = claimedAnchor.generation
    }
  }

  private func recordAttempt(
    for displayID: DisplayID,
    at date: Date,
    claimedAnchor: ClaimedAnchor?
  ) {
    var state = states[displayID] ?? DisplayState()
    state.lastCadenceAt = date
    if claimedAnchor != nil { state.lastAnchorAttemptAt = date }
    states[displayID] = state
  }

  private func recordStableObservation(
    for displayID: DisplayID,
    at date: Date,
    fingerprint: ScreenFrameFingerprint,
    claimedAnchor: ClaimedAnchor?
  ) {
    var state = states[displayID] ?? DisplayState()
    state.lastCadenceAt = date
    state.lastObservedFingerprint = fingerprint
    if claimedAnchor != nil {
      state.lastAnchorAttemptAt = date
    } else {
      let current = state.ordinaryInterval ?? minimumInterval
      state.ordinaryInterval = min(maximumInterval, max(minimumInterval, current * 2))
    }
    states[displayID] = state
  }

  private func recordSignificantAttempt(
    for displayID: DisplayID,
    at date: Date,
    fingerprint: ScreenFrameFingerprint? = nil,
    claimedAnchor: ClaimedAnchor?
  ) {
    var state = states[displayID] ?? DisplayState()
    state.lastCadenceAt = date
    state.ordinaryInterval = minimumInterval
    if let fingerprint { state.lastObservedFingerprint = fingerprint }
    if claimedAnchor != nil { state.lastAnchorAttemptAt = date }
    states[displayID] = state
  }

  private static func fingerprint(_ pixelBuffer: CVPixelBuffer) -> ScreenFrameFingerprint? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return nil
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let columns = min(width, 16)
    let rows = min(height, 9)
    var samples: [ScreenFrameFingerprint.Sample] = []
    samples.reserveCapacity(columns * rows)
    for row in 0..<rows {
      let minY = row * height / rows
      let maxY = max(minY, ((row + 1) * height / rows) - 1)
      for column in 0..<columns {
        let minX = column * width / columns
        let maxX = max(minX, ((column + 1) * width / columns) - 1)
        let positions = [
          (minX, minY),
          (maxX, minY),
          (minX, maxY),
          (maxX, maxY),
        ]
        var red = 0
        var green = 0
        var blue = 0
        for (x, y) in positions {
          let offset = y * bytesPerRow + x * 4
          blue += Int(bytes[offset])
          green += Int(bytes[offset + 1])
          red += Int(bytes[offset + 2])
        }
        samples.append(
          ScreenFrameFingerprint.Sample(
            red: UInt8(red / positions.count),
            green: UInt8(green / positions.count),
            blue: UInt8(blue / positions.count)
          ))
      }
    }
    return ScreenFrameFingerprint(
      pixelWidth: width,
      pixelHeight: height,
      samples: samples
    )
  }
}

/// A bounded 16x9 perceptual signature. Each cell averages four pixels, reducing sensitivity to a
/// blinking caret, mouse cursor, clock digit, or other tiny animation without retaining an image.
private struct ScreenFrameFingerprint: Sendable {
  struct Sample: Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
  }

  private static let changedCellChannelThreshold = 24
  private static let globalMeanChannelThreshold = 12
  private static let changedCellRatioDivisor = 20
  private static let minimumChangedCellCount = 4

  let pixelWidth: Int
  let pixelHeight: Int
  let samples: [Sample]

  func isSignificantlyDifferent(from previous: ScreenFrameFingerprint) -> Bool {
    guard pixelWidth == previous.pixelWidth, pixelHeight == previous.pixelHeight,
      samples.count == previous.samples.count, !samples.isEmpty
    else { return true }

    var changedCellCount = 0
    var totalMeanChannelDelta = 0
    for (sample, prior) in zip(samples, previous.samples) {
      let redDelta = abs(Int(sample.red) - Int(prior.red))
      let greenDelta = abs(Int(sample.green) - Int(prior.green))
      let blueDelta = abs(Int(sample.blue) - Int(prior.blue))
      if max(redDelta, greenDelta, blueDelta) >= Self.changedCellChannelThreshold {
        changedCellCount += 1
      }
      totalMeanChannelDelta += (redDelta + greenDelta + blueDelta) / 3
    }

    let changedCellThreshold = max(
      Self.minimumChangedCellCount,
      (samples.count + Self.changedCellRatioDivisor - 1) / Self.changedCellRatioDivisor
    )
    return changedCellCount >= changedCellThreshold
      || totalMeanChannelDelta / samples.count >= Self.globalMeanChannelThreshold
  }
}

private enum ScreenCredentialRedactor {
  private static let sensitiveKeywords = [
    "password", "passcode", "verification code", "one-time code", "two-factor", "2fa",
    "api key", "access token", "secret key", "private key", "recovery phrase",
    "密码", "验证码", "口令", "密钥", "令牌", "助记词",
  ]

  static func redact(_ recognitions: [ScreenTextRecognition]) -> (
    lines: [RedactedOCRLine],
    didRemoveContent: Bool,
    sensitiveBounds: [CGRect]
  ) {
    var result: [RedactedOCRLine] = []
    var seen = Set<String>()
    var didRemoveContent = false
    var sensitiveBounds: [CGRect] = []

    for recognition in recognitions {
      let rawLine = recognition.text
      let normalized = rawLine.split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
      guard !normalized.isEmpty else { continue }
      guard !isSensitive(normalized) else {
        didRemoveContent = true
        if !recognition.normalizedBoundingBox.isEmpty {
          sensitiveBounds.append(recognition.normalizedBoundingBox)
        }
        continue
      }

      let bounded = boundedUTF8(normalized, maximum: RedactedOCRLine.maximumUTF8Length)
      if bounded != normalized { didRemoveContent = true }
      guard !bounded.isEmpty, seen.insert(bounded).inserted,
        let line = try? RedactedOCRLine(bounded)
      else {
        continue
      }
      if result.count < OCRArtifact.maximumLineCount {
        result.append(line)
      } else {
        // Continue scanning every remaining recognition for sensitive bounds even after the
        // durable OCR line budget is full. Stopping here could leave a later credential visible
        // in the remote derivative.
        didRemoveContent = true
      }
    }
    return (result, didRemoveContent, sensitiveBounds)
  }

  private static func isSensitive(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if sensitiveKeywords.contains(where: lowercased.contains) { return true }
    if lowercased.contains("sk-") && value.count >= 12 { return true }
    if ["authorization:", "bearer ", "token=", "token:", "secret=", "apikey=", "api_key="]
      .contains(where: lowercased.contains)
    {
      return true
    }

    let digits = value.filter(\.isNumber)
    let nonSpacingCharacters = value.filter { !$0.isWhitespace }
    if digits.count == nonSpacingCharacters.count, (4...8).contains(digits.count) {
      return true
    }
    if (13...19).contains(digits.count), Self.passesLuhn(digits) {
      return true
    }

    let tokens = value.split { character in
      character.isWhitespace || character.isPunctuation
    }
    return tokens.contains { token in
      let value = String(token)
      if value.lowercased().hasPrefix("sk-") && value.count >= 12 { return true }
      if value.hasPrefix("eyJ") && value.count >= 24 { return true }
      if value.hasPrefix("AKIA") && value.count == 20 { return true }
      if value.count >= 32 && value.allSatisfy(\.isHexDigit) { return true }
      if value.count >= 40,
        value.allSatisfy({ $0.isLetter || $0.isNumber || "+/=_-".contains($0) })
      {
        return true
      }
      return false
    }
  }

  private static func passesLuhn(_ digits: String) -> Bool {
    var sum = 0
    var shouldDouble = false
    for character in digits.reversed() {
      guard var digit = character.wholeNumberValue else { return false }
      if shouldDouble {
        digit *= 2
        if digit > 9 { digit -= 9 }
      }
      sum += digit
      shouldDouble.toggle()
    }
    return sum % 10 == 0
  }

  private static func boundedUTF8(_ value: String, maximum: Int) -> String {
    guard value.utf8.count > maximum else { return value }
    var result = ""
    for character in value {
      guard result.utf8.count + String(character).utf8.count <= maximum else { break }
      result.append(character)
    }
    return result
  }
}

private enum ScreenVisionDerivativeEncoder {
  private static let maximumDimension = 1_600
  private static let jpegQuality = 0.72

  static func encode(
    _ pixelBuffer: CVPixelBuffer,
    redacting normalizedBounds: [CGRect]
  ) -> PreparedScreenVisionDerivative? {
    let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
    let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
    guard sourceWidth > 0, sourceHeight > 0 else { return nil }

    let scale = min(1, Double(maximumDimension) / Double(max(sourceWidth, sourceHeight)))
    let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
    let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.interpolationQuality = .medium
    guard Self.draw(pixelBuffer, into: context, width: width, height: height) else { return nil }
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    for normalized in normalizedBounds {
      let clipped = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !clipped.isNull, !clipped.isEmpty else { continue }
      let padding = max(3, CGFloat(height) * 0.006)
      let rect = CGRect(
        x: clipped.minX * CGFloat(width),
        y: clipped.minY * CGFloat(height),
        width: clipped.width * CGFloat(width),
        height: clipped.height * CGFloat(height)
      ).insetBy(dx: -padding, dy: -padding)
      context.fill(rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
    }
    guard let redactedImage = context.makeImage() else { return nil }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else { return nil }
    CGImageDestinationAddImage(
      destination,
      redactedImage,
      [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return PreparedScreenVisionDerivative(
      encodedJPEG: output as Data,
      pixelWidth: width,
      pixelHeight: height
    )
  }

  /// Draws while the pixel buffer remains locked, so the provider may borrow its bytes without a
  /// second full-resolution `Data` allocation. The destination context owns the downscaled copy
  /// before this function unlocks the ephemeral source surface.
  private static func draw(
    _ pixelBuffer: CVPixelBuffer,
    into context: CGContext,
    width destinationWidth: Int,
    height destinationHeight: Int
  ) -> Bool {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return false
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard
      let provider = CGDataProvider(
        dataInfo: nil,
        data: baseAddress,
        size: bytesPerRow * height,
        releaseData: { _, _, _ in }
      ),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else { return false }
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight)
    )
    return true
  }
}
