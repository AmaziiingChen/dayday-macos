@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import DaydayCore
import Foundation

/// Objective metadata that is safe to hand to downstream components after the
/// corresponding image surface has been released.
///
/// This value deliberately contains no pixels, OCR text, window title, file
/// location, or generic payload. It is not `Codable`; persistence requires a
/// separate, privacy-reviewed evidence contract.
public struct ObjectiveScreenFrameMetadata: Sendable, Equatable {
    public let display: DisplayContext
    public let observedAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        display: DisplayContext,
        observedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.display = display
        self.observedAt = observedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A sendability boundary for ScreenCaptureKit's reference-counted sample.
/// The wrapper and its raw value are module-internal and never cross DaydayCapture's API.
struct CapturedScreenSample: @unchecked Sendable {
    fileprivate let sampleBuffer: CMSampleBuffer

    init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

/// A short-lived frame admitted to the bounded processing lane.
///
/// Raw media remains private to this type. Trusted Capture processors can only
/// borrow its image buffer through a nonescaping closure. The type has no
/// serialization or file representation.
final class EphemeralScreenFrame: @unchecked Sendable {
    let metadata: ObjectiveScreenFrameMetadata
    private let sampleBuffer: CMSampleBuffer

    init?(
        sample: CapturedScreenSample,
        display: DisplayContext,
        observedAt: Date
    ) {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              CMSampleBufferDataIsReady(sample.sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample.sampleBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        self.sampleBuffer = sample.sampleBuffer
        self.metadata = ObjectiveScreenFrameMetadata(
            display: display,
            observedAt: observedAt,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    /// The closure is nonescaping. Callers must finish all raw-surface work before returning.
    func withPixelBuffer<Result>(_ body: (CVPixelBuffer) throws -> Result) rethrows -> Result? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return try body(pixelBuffer)
    }
}

/// One in-flight frame plus one replaceable latest-frame slot. A slow processor
/// can never create an unbounded queue: a newer pending frame releases the older
/// pending sample immediately.
final class EphemeralFramePump: @unchecked Sendable {
    /// A processor runs synchronously and serially on the pump queue. It may
    /// inspect the borrowed pixel buffer only during the call. It must not
    /// publish, persist, log, or send raw or derived frame content itself;
    /// externally visible delivery must go through the generation-gated
    /// completion below.
    ///
    /// `deactivate()` drops pending work and suppresses completion, but cannot
    /// preempt a processor call already executing. Processors must therefore be
    /// bounded and return promptly. This is the cancellation contract for the
    /// ephemeral lane.
    typealias Processor = @Sendable (EphemeralScreenFrame) -> EphemeralFrameAnalysis?
    typealias Completion = @Sendable (
        ObjectiveScreenFrameMetadata,
        EphemeralFrameAnalysis?,
        UInt64
    ) -> Void

    private struct PendingFrame {
        let frame: EphemeralScreenFrame
        let generation: UInt64
        let completion: Completion
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let processor: Processor
    private var activeGeneration: UInt64?
    private var isProcessing = false
    private var pending: PendingFrame?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.dayday.capture.ephemeral-frame",
            qos: .utility
        ),
        processor: @escaping Processor
    ) {
        self.queue = queue
        self.processor = processor
    }

    func activate(generation: UInt64) {
        lock.withLock {
            activeGeneration = generation
            pending = nil
        }
    }

    func deactivate() {
        lock.withLock {
            activeGeneration = nil
            pending = nil
        }
    }

    func submit(
        _ frame: EphemeralScreenFrame,
        generation: UInt64,
        completion: @escaping Completion
    ) {
        let item = PendingFrame(frame: frame, generation: generation, completion: completion)
        let shouldSchedule = lock.withLock { () -> Bool in
            guard activeGeneration == generation else { return false }
            guard !isProcessing else {
                pending = item
                return false
            }
            isProcessing = true
            return true
        }

        if shouldSchedule {
            schedule(item)
        }
    }

    private func schedule(_ first: PendingFrame) {
        queue.async { [self] in
            var current: PendingFrame? = first
            while let item = current {
                let analysis = processor(item.frame)

                let result = lock.withLock { () -> (Bool, PendingFrame?) in
                    let mayDeliver = activeGeneration == item.generation
                    if let next = pending, activeGeneration == next.generation {
                        pending = nil
                        return (mayDeliver, next)
                    }
                    pending = nil
                    isProcessing = false
                    return (mayDeliver, nil)
                }

                if result.0 {
                    item.completion(item.frame.metadata, analysis, item.generation)
                }
                current = result.1
            }
        }
    }
}
