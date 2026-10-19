import CoreFoundation
import Foundation

/// A private run-loop owner for CoreGraphics event taps.
///
/// Input Monitoring callbacks must never share the app's main run loop. This
/// helper serializes installation and teardown on one long-lived thread, while
/// leaving SwiftUI and editor work free to render and accept IME composition.
final class InputEventTapThread: @unchecked Sendable {
    enum Error: Swift.Error {
        case unavailable
    }

    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var thread: Thread!

    init(name: String = "app.dayday.input-event-tap") {
        thread = Thread { [weak self] in self?.run() }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    deinit {
        stop()
    }

    func performAndWait(_ operation: @escaping @Sendable (CFRunLoop) -> Void) throws {
        let completion = DispatchSemaphore(value: 0)
        let loop = lock.withLock { runLoop }
        guard let loop, !lock.withLock({ stopping }) else { throw Error.unavailable }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            operation(loop)
            completion.signal()
        }
        CFRunLoopWakeUp(loop)
        completion.wait()
    }

    func stop() {
        let loop = lock.withLock { () -> CFRunLoop? in
            guard !stopping else { return nil }
            stopping = true
            return runLoop
        }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()
        // A bare `CFRunLoopRun()` returns as soon as there are no sources. The
        // thread is deliberately created before a consented session installs
        // its tap, so retain one inert source to keep the run loop available
        // between construction and the first `performAndWait` call.
        var context = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: nil
        )
        guard let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            started.signal()
            return
        }
        CFRunLoopAddSource(loop, keepAlive, .commonModes)
        lock.withLock { runLoop = loop }
        started.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, keepAlive, .commonModes)
        lock.withLock { runLoop = nil }
    }
}
