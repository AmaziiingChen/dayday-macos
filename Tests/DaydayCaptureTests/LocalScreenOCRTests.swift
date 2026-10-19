@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import DaydayCore
import Foundation
@preconcurrency import ImageIO
import Testing

@testable import DaydayCapture

struct LocalScreenOCRTests {
  @Test
  func ordinaryReadingSurfaceWithoutFocusedControlRemainsEligible() {
    #expect(MacOSScreenOCRSafetyGate.permitsFocusedElement(role: nil, subrole: nil))
    #expect(
      MacOSScreenOCRSafetyGate.permitsFocusedElement(
        role: "AXStaticText",
        subrole: nil
      ))
    #expect(
      !MacOSScreenOCRSafetyGate.permitsFocusedElement(
        role: "AXSecureTextField",
        subrole: nil
      ))
    #expect(
      !MacOSScreenOCRSafetyGate.permitsFocusedElement(
        role: "AXTextField",
        subrole: "AXAuthenticationField"
      ))
  }

  @Test
  func rateLimitsDeduplicatesAndRemovesCredentialLines() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: [
      "Project notes",
      "API key sk-example-secret-value",
      "Project notes",
    ])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 30
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    let first = try #require(try frame(display: display, at: start, fill: 1))
    let firstResult = try #require(processor.process(first))
    #expect(firstResult.lines.map(\.value) == ["Project notes"])
    #expect(firstResult.redactionApplied)
    #expect(recognizer.callCount == 1)

    let rateLimited = try #require(
      try frame(
        display: display,
        at: start.addingTimeInterval(10),
        fill: 2
      ))
    #expect(processor.process(rateLimited) == nil)
    #expect(recognizer.callCount == 1)

    let unchanged = try #require(
      try frame(
        display: display,
        at: start.addingTimeInterval(31),
        fill: 1
      ))
    #expect(processor.process(unchanged) == nil)
    #expect(recognizer.callCount == 1)

    let changed = try #require(
      try frame(
        display: display,
        at: start.addingTimeInterval(92),
        fill: 100
      ))
    #expect(processor.process(changed) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func anchorBypassesCadenceButStillDeduplicatesUnchangedFrame() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Draft reply"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 30
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_500)
    let first = try #require(try frame(display: display, at: start, fill: 10))
    #expect(processor.process(first) != nil)

    processor.requestImmediateProcessing()
    let changed = try #require(
      try frame(display: display, at: start.addingTimeInterval(1), fill: 100)
    )
    #expect(processor.process(changed) != nil)
    #expect(recognizer.callCount == 2)

    processor.requestImmediateProcessing()
    let unchanged = try #require(
      try frame(display: display, at: start.addingTimeInterval(2), fill: 100)
    )
    #expect(processor.process(unchanged) == nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func stableFramesBackOffPeriodicCadenceFromOneToFiveMinutes() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Stable document"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true)
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_550)

    let baseline = try #require(try frame(display: display, at: start, fill: 20))
    #expect(processor.process(baseline) != nil)

    let firstStable = try #require(
      try frame(display: display, at: start.addingTimeInterval(60), fill: 20)
    )
    #expect(processor.process(firstStable) == nil)

    let beforeTwoMinutes = try #require(
      try frame(display: display, at: start.addingTimeInterval(179), fill: 200)
    )
    #expect(processor.process(beforeTwoMinutes) == nil)
    let secondStable = try #require(
      try frame(display: display, at: start.addingTimeInterval(180), fill: 20)
    )
    #expect(processor.process(secondStable) == nil)

    let beforeFourMinutes = try #require(
      try frame(display: display, at: start.addingTimeInterval(419), fill: 200)
    )
    #expect(processor.process(beforeFourMinutes) == nil)
    let thirdStable = try #require(
      try frame(display: display, at: start.addingTimeInterval(420), fill: 20)
    )
    #expect(processor.process(thirdStable) == nil)

    let beforeFiveMinutes = try #require(
      try frame(display: display, at: start.addingTimeInterval(719), fill: 200)
    )
    #expect(processor.process(beforeFiveMinutes) == nil)
    let fourthStable = try #require(
      try frame(display: display, at: start.addingTimeInterval(720), fill: 20)
    )
    #expect(processor.process(fourthStable) == nil)

    let cappedBeforeFiveMinutes = try #require(
      try frame(display: display, at: start.addingTimeInterval(1_019), fill: 200)
    )
    #expect(processor.process(cappedBeforeFiveMinutes) == nil)
    let changedAtFiveMinutes = try #require(
      try frame(display: display, at: start.addingTimeInterval(1_020), fill: 200)
    )
    #expect(processor.process(changedAtFiveMinutes) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func significantChangeResetsPeriodicCadenceToOneMinute() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Changed document"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true)
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_575)

    let baseline = try #require(try frame(display: display, at: start, fill: 20))
    #expect(processor.process(baseline) != nil)
    let stable = try #require(
      try frame(display: display, at: start.addingTimeInterval(60), fill: 20)
    )
    #expect(processor.process(stable) == nil)

    let changed = try #require(
      try frame(
        display: display,
        at: start.addingTimeInterval(180),
        fill: 20,
        patch: FramePatch(x: 0..<16, y: 0..<18, fill: 180)
      )
    )
    #expect(processor.process(changed) != nil)
    let beforeResetCadence = try #require(
      try frame(display: display, at: start.addingTimeInterval(239), fill: 20)
    )
    #expect(processor.process(beforeResetCadence) == nil)
    let atResetCadence = try #require(
      try frame(display: display, at: start.addingTimeInterval(240), fill: 20)
    )
    #expect(processor.process(atResetCadence) != nil)
    #expect(recognizer.callCount == 3)
  }

  @Test
  func localizedAnimationNoiseDoesNotResetBackoff() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Document with clock"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true)
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_600)

    let baseline = try #require(try frame(display: display, at: start, fill: 100))
    #expect(processor.process(baseline) != nil)
    let clockOrCursorChange = try #require(
      try frame(
        display: display,
        at: start.addingTimeInterval(60),
        fill: 100,
        patch: FramePatch(x: 0..<4, y: 0..<4, fill: 250)
      )
    )
    #expect(processor.process(clockOrCursorChange) == nil)
    #expect(recognizer.callCount == 1)

    let beforeBackedOffCadence = try #require(
      try frame(display: display, at: start.addingTimeInterval(179), fill: 220)
    )
    #expect(processor.process(beforeBackedOffCadence) == nil)
    let significantAtBackedOffCadence = try #require(
      try frame(display: display, at: start.addingTimeInterval(180), fill: 220)
    )
    #expect(processor.process(significantAtBackedOffCadence) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func anchorBypassesAdaptiveBackoff() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Submitted work"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true)
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_625)

    let baseline = try #require(try frame(display: display, at: start, fill: 20))
    #expect(processor.process(baseline) != nil)
    let stable = try #require(
      try frame(display: display, at: start.addingTimeInterval(60), fill: 20)
    )
    #expect(processor.process(stable) == nil)

    processor.requestImmediateProcessing()
    let anchored = try #require(
      try frame(display: display, at: start.addingTimeInterval(61), fill: 180)
    )
    #expect(processor.process(anchored) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func repeatedAnchorsCoalesceUntilCooldownExpires() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Review implementation"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 60,
      anchorCooldown: 5
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_700)

    let baseline = try #require(try frame(display: display, at: start, fill: 20))
    #expect(processor.process(baseline) != nil)

    processor.requestImmediateProcessing()
    let firstAnchor = try #require(
      try frame(display: display, at: start.addingTimeInterval(1), fill: 100)
    )
    #expect(processor.process(firstAnchor) != nil)

    processor.requestImmediateProcessing()
    processor.requestImmediateProcessing()
    let coolingDown = try #require(
      try frame(display: display, at: start.addingTimeInterval(3), fill: 180)
    )
    #expect(processor.process(coolingDown) == nil)
    #expect(recognizer.callCount == 2)

    let afterCooldown = try #require(
      try frame(display: display, at: start.addingTimeInterval(6), fill: 180)
    )
    #expect(processor.process(afterCooldown) != nil)
    #expect(recognizer.callCount == 3)

    let duplicateAfterClaim = try #require(
      try frame(display: display, at: start.addingTimeInterval(7), fill: 240)
    )
    #expect(processor.process(duplicateAfterClaim) == nil)
    #expect(recognizer.callCount == 3)
  }

  @Test
  func globalLaneDeferralRetainsAnchorAndDoesNotConsumeCadence() throws {
    let coordinator = ScreenOCRExecutionCoordinator()
    let recognizer = CoordinatedFixtureScreenTextRecognizer(
      lines: ["Latest work context"],
      coordinator: coordinator
    )
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 60,
      anchorCooldown: 0
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_800)

    let baseline = try #require(try frame(display: display, at: start, fill: 30))
    #expect(processor.process(baseline) != nil)

    processor.requestImmediateProcessing()
    let competingLease = try #require(coordinator.tryAcquire())
    let deferred = try #require(
      try frame(display: display, at: start.addingTimeInterval(1), fill: 130)
    )
    #expect(processor.process(deferred) == nil)
    #expect(recognizer.callCount == 1)
    competingLease.release()

    let latest = try #require(
      try frame(display: display, at: start.addingTimeInterval(2), fill: 230)
    )
    #expect(processor.process(latest) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func globalLaneDeferralDoesNotConsumePeriodicCadence() throws {
    let coordinator = ScreenOCRExecutionCoordinator()
    let recognizer = CoordinatedFixtureScreenTextRecognizer(
      lines: ["Periodic screen evidence"],
      coordinator: coordinator
    )
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 60
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_825)

    let baseline = try #require(try frame(display: display, at: start, fill: 33))
    #expect(processor.process(baseline) != nil)

    let competingLease = try #require(coordinator.tryAcquire())
    let deferred = try #require(
      try frame(display: display, at: start.addingTimeInterval(61), fill: 133)
    )
    #expect(processor.process(deferred) == nil)
    #expect(recognizer.callCount == 1)
    competingLease.release()

    let retry = try #require(
      try frame(display: display, at: start.addingTimeInterval(62), fill: 233)
    )
    #expect(processor.process(retry) != nil)
    #expect(recognizer.callCount == 2)
  }

  @Test
  func processorsSharingCoordinatorNeverRecognizeConcurrently() throws {
    let coordinator = ScreenOCRExecutionCoordinator()
    let firstRecognizer = BlockingCoordinatedScreenTextRecognizer(
      lines: ["First display"],
      coordinator: coordinator
    )
    let secondRecognizer = CoordinatedFixtureScreenTextRecognizer(
      lines: ["Second display"],
      coordinator: coordinator
    )
    let firstProcessor = LocalScreenOCRProcessor(
      recognizer: firstRecognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 0
    )
    let secondProcessor = LocalScreenOCRProcessor(
      recognizer: secondRecognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 0
    )
    let start = Date(timeIntervalSinceReferenceDate: 1_850)
    let firstFrame = try #require(
      try frame(
        display: DisplayContext(id: DisplayID(), topologyRevision: 1),
        at: start,
        fill: 35
      )
    )
    let secondDisplay = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let competingFrame = try #require(
      try frame(display: secondDisplay, at: start, fill: 36)
    )
    let firstFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      _ = firstProcessor.process(firstFrame)
      firstFinished.signal()
    }
    try #require(firstRecognizer.waitUntilRecognitionStarts())
    defer { firstRecognizer.releaseRecognition() }

    #expect(secondProcessor.process(competingFrame) == nil)
    #expect(secondRecognizer.callCount == 0)

    firstRecognizer.releaseRecognition()
    #expect(firstFinished.wait(timeout: .now() + 2) == .success)
    let retryFrame = try #require(
      try frame(
        display: secondDisplay,
        at: start.addingTimeInterval(1),
        fill: 37
      )
    )
    #expect(secondProcessor.process(retryFrame) != nil)
    #expect(firstRecognizer.callCount == 1)
    #expect(secondRecognizer.callCount == 1)
  }

  @Test
  func cancellingAfterDeferralDoesNotResurrectPendingAnchor() throws {
    let coordinator = ScreenOCRExecutionCoordinator()
    let recognizer = CoordinatedFixtureScreenTextRecognizer(
      lines: ["Current document"],
      coordinator: coordinator
    )
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 60,
      anchorCooldown: 0
    )
    let display = DisplayContext(id: DisplayID(), topologyRevision: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_900)

    let baseline = try #require(try frame(display: display, at: start, fill: 40))
    #expect(processor.process(baseline) != nil)

    processor.requestImmediateProcessing()
    let competingLease = try #require(coordinator.tryAcquire())
    let deferred = try #require(
      try frame(display: display, at: start.addingTimeInterval(1), fill: 140)
    )
    #expect(processor.process(deferred) == nil)
    processor.cancelPendingProcessing()
    competingLease.release()

    let afterCancellation = try #require(
      try frame(display: display, at: start.addingTimeInterval(2), fill: 240)
    )
    #expect(processor.process(afterCancellation) == nil)
    #expect(recognizer.callCount == 1)
  }

  @Test
  func fullySensitiveRecognitionProducesContentFreeSuppressionSignal() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: [
      "Password: hunter2",
      "sk-0123456789abcdef",
      "123456",
      "Authorization: Bearer opaque-value",
      "4111 1111 1111 1111",
    ])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 0
    )
    let sensitiveFrame = try #require(
      try frame(
        display: DisplayContext(id: DisplayID(), topologyRevision: 1),
        at: Date(timeIntervalSinceReferenceDate: 2_000),
        fill: 3
      ))
    let result = try #require(processor.process(sensitiveFrame))

    #expect(result.lines.isEmpty)
    #expect(result.redactionApplied)
  }

  @Test
  func visualDerivativeRemainsEligibleWhenLocalOCRFindsNoText() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: [])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 0
    )
    let source = try #require(
      try frame(
        display: DisplayContext(id: DisplayID(), topologyRevision: 1),
        at: Date(timeIntervalSinceReferenceDate: 2_500),
        fill: 8
      ))

    let result = try #require(processor.process(source))
    #expect(result.lines.isEmpty)
    #expect(!result.redactionApplied)
    #expect(result.visionDerivative?.encodedJPEG.starts(with: [0xFF, 0xD8]) == true)
  }

  @Test
  func safetyDenialPreventsAnyPixelRecognition() throws {
    let recognizer = FixtureScreenTextRecognizer(lines: ["Must not leave the frame lane"])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: false),
      minimumInterval: 0
    )
    let deniedFrame = try #require(
      try frame(
        display: DisplayContext(id: DisplayID(), topologyRevision: 1),
        at: Date(timeIntervalSinceReferenceDate: 3_000),
        fill: 4
      )
    )

    #expect(processor.process(deniedFrame) == nil)
    #expect(recognizer.callCount == 0)
  }

  @Test
  func producesDownscaledJPEGAndMasksSensitiveRecognitionBounds() throws {
    let ordinary = (0..<OCRArtifact.maximumLineCount).map {
      ScreenTextRecognition(text: "ordinary line \($0)")
    }
    let recognizer = FixtureScreenTextRecognizer(
      recognitions: ordinary + [
        ScreenTextRecognition(
          text: "Password: visible-secret",
          normalizedBoundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
      ])
    let processor = LocalScreenOCRProcessor(
      recognizer: recognizer,
      safetyGate: FixtureScreenOCRSafetyGate(permits: true),
      minimumInterval: 0
    )
    let source = try #require(
      try frame(
        display: DisplayContext(id: DisplayID(), topologyRevision: 1),
        at: Date(timeIntervalSinceReferenceDate: 4_000),
        fill: 255
      )
    )
    let result = try #require(processor.process(source))
    let derivative = try #require(result.visionDerivative)

    #expect(result.lines.count == OCRArtifact.maximumLineCount)
    #expect(result.redactionApplied)
    #expect(derivative.pixelWidth == 32)
    #expect(derivative.pixelHeight == 18)
    #expect(derivative.encodedJPEG.starts(with: [0xFF, 0xD8]))
    let imageSource = try #require(
      CGImageSourceCreateWithData(derivative.encodedJPEG as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    var pixel = [UInt8](repeating: 255, count: 4)
    let context = try #require(
      CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    #expect(pixel[0] < 50)
    #expect(pixel[1] < 50)
    #expect(pixel[2] < 50)
  }

  private func frame(
    display: DisplayContext,
    at date: Date,
    fill: UInt8,
    patch: FramePatch? = nil
  ) throws -> EphemeralScreenFrame? {
    var pixelBuffer: CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
      kCFAllocatorDefault,
      32,
      18,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
      throw LocalScreenOCRTestError.pixelBufferCreationFailed(pixelStatus)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(address, Int32(fill), CVPixelBufferGetDataSize(pixelBuffer))
      if let patch {
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in patch.y.clamped(to: 0..<18) {
          for x in patch.x.clamped(to: 0..<32) {
            let offset = y * bytesPerRow + x * 4
            bytes[offset] = patch.fill
            bytes[offset + 1] = patch.fill
            bytes[offset + 2] = patch.fill
            bytes[offset + 3] = patch.fill
          }
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
      throw LocalScreenOCRTestError.formatDescriptionCreationFailed(formatStatus)
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw LocalScreenOCRTestError.sampleBufferCreationFailed(sampleStatus)
    }
    return EphemeralScreenFrame(
      sample: CapturedScreenSample(sampleBuffer: sampleBuffer),
      display: display,
      observedAt: date
    )
  }
}

private struct FramePatch {
  let x: Range<Int>
  let y: Range<Int>
  let fill: UInt8
}

extension Range where Bound == Int {
  fileprivate func clamped(to bounds: Range<Int>) -> Range<Int> {
    Swift.max(lowerBound, bounds.lowerBound)..<Swift.min(upperBound, bounds.upperBound)
  }
}

private struct FixtureScreenOCRSafetyGate: ScreenOCRSafetyEvaluating {
  let permits: Bool

  func permitsOCR() -> Bool { permits }
}

private final class FixtureScreenTextRecognizer: ScreenTextRecognizing, @unchecked Sendable {
  private let lock = NSLock()
  private let recognitions: [ScreenTextRecognition]
  private var calls = 0

  init(lines: [String]) {
    self.recognitions = lines.map { ScreenTextRecognition(text: $0) }
  }

  init(recognitions: [ScreenTextRecognition]) {
    self.recognitions = recognitions
  }

  var callCount: Int { lock.withLock { calls } }

  func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition] {
    lock.withLock { calls += 1 }
    return recognitions
  }
}

private final class CoordinatedFixtureScreenTextRecognizer: ScreenTextRecognizing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let recognitions: [ScreenTextRecognition]
  private let coordinator: ScreenOCRExecutionCoordinator
  private var calls = 0

  init(lines: [String], coordinator: ScreenOCRExecutionCoordinator) {
    self.recognitions = lines.map { ScreenTextRecognition(text: $0) }
    self.coordinator = coordinator
  }

  var callCount: Int { lock.withLock { calls } }

  func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition] {
    lock.withLock { calls += 1 }
    return recognitions
  }

  func attemptRecognition(in pixelBuffer: CVPixelBuffer) throws -> ScreenTextRecognitionAttempt {
    guard let lease = coordinator.tryAcquire() else { return .deferred }
    defer { lease.release() }
    return .completed(try recognizeText(in: pixelBuffer))
  }
}

private final class BlockingCoordinatedScreenTextRecognizer: ScreenTextRecognizing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let recognitions: [ScreenTextRecognition]
  private let coordinator: ScreenOCRExecutionCoordinator
  private let started = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private var calls = 0
  private var didRelease = false

  init(lines: [String], coordinator: ScreenOCRExecutionCoordinator) {
    self.recognitions = lines.map { ScreenTextRecognition(text: $0) }
    self.coordinator = coordinator
  }

  var callCount: Int { lock.withLock { calls } }

  func recognizeText(in pixelBuffer: CVPixelBuffer) throws -> [ScreenTextRecognition] {
    lock.withLock { calls += 1 }
    return recognitions
  }

  func attemptRecognition(in pixelBuffer: CVPixelBuffer) throws -> ScreenTextRecognitionAttempt {
    guard let lease = coordinator.tryAcquire() else { return .deferred }
    defer { lease.release() }
    started.signal()
    _ = release.wait(timeout: .now() + 2)
    return .completed(try recognizeText(in: pixelBuffer))
  }

  func waitUntilRecognitionStarts() -> Bool {
    started.wait(timeout: .now() + 2) == .success
  }

  func releaseRecognition() {
    let shouldSignal = lock.withLock { () -> Bool in
      guard !didRelease else { return false }
      didRelease = true
      return true
    }
    if shouldSignal { release.signal() }
  }
}

private enum LocalScreenOCRTestError: Error {
  case pixelBufferCreationFailed(CVReturn)
  case formatDescriptionCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)
}
