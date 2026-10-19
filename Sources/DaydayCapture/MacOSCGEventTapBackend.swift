import Carbon
import CoreGraphics
import Foundation

enum MacOSCGEventTapBackendError: Error, Equatable, Sendable {
    case alreadyRunning
    case tapCreationFailed
    case runLoopSourceCreationFailed
}

/// Maps opaque event-tap tokens to callback state without exposing a Swift object address to C.
///
/// CoreGraphics may deliver a callback near a tap teardown boundary. A token remains harmless
/// after removal: a late callback performs a failed lookup instead of dereferencing released
/// memory. The registry holds its lock while invoking a registered value so removal also waits
/// for an already-running callback to return.
final class EventTapCallbackRegistry<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var values: [UInt: Value] = [:]

    func insert(_ value: Value) -> UInt {
        lock.withLock {
            let token = nextAvailableToken()
            values[token] = value
            return token
        }
    }

    func withValue(for token: UInt, _ operation: (Value) -> Void) {
        lock.withLock {
            guard let value = values[token] else { return }
            operation(value)
        }
    }

    @discardableResult
    func removeValue(for token: UInt) -> Value? {
        lock.withLock { values.removeValue(forKey: token) }
    }

    func contains(_ token: UInt) -> Bool {
        lock.withLock { values[token] != nil }
    }

    private func nextAvailableToken() -> UInt {
        while true {
            let candidate = nextToken
            nextToken = candidate == .max ? 1 : candidate + 1
            if values[candidate] == nil { return candidate }
        }
    }
}

/// A listen-only session event tap. It extracts only the closed transient facts
/// consumed by `CGEventTapInputCollector`; characters, modifier combinations,
/// source-process data, and event objects never leave the callback.
final class MacOSCGEventTapBackend: InputEventTapBackend, @unchecked Sendable {
    private typealias EventCallback = (CGEventType, CGEvent) -> Void

    nonisolated private static let callbackRegistry = EventTapCallbackRegistry<EventCallback>()

    private final class CallbackBox: @unchecked Sendable {
        let mailbox: InputEventMailbox
        let sessionID: UInt64
        let clock: @Sendable () -> Date
        private var modifierPresses = ModifierKeyPressReducer()

        init(
            mailbox: InputEventMailbox,
            sessionID: UInt64,
            clock: @escaping @Sendable () -> Date
        ) {
            self.mailbox = mailbox
            self.sessionID = sessionID
            self.clock = clock
        }

        func receive(type: CGEventType, event: CGEvent) {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                deliver(.tapDisabled)
                return
            default:
                break
            }

            // Do not call TCC, Accessibility, secure-input probes, persistence, or MainActor
            // presentation code here. This callback participates in the system input path and
            // must return immediately so accepting an IME candidate cannot be delayed. The
            // collector actor revalidates authorization and secure input before it records the
            // transient event; a failed gate is discarded and closes the tap.
            guard
                let transient = makeTransientEvent(
                    type: type,
                    event: event,
                    observedAt: clock()
                )
            else {
                return
            }
            deliver(transient)
        }

        private func deliver(_ event: TransientInputEvent) {
            mailbox.offer(event, sessionID: sessionID)
        }

        private func makeTransientEvent(
            type: CGEventType,
            event: CGEvent,
            observedAt: Date
        ) -> TransientInputEvent? {
            guard observedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            switch type {
            case .keyDown:
                let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard rawCode >= 0, rawCode <= Int64(UInt16.max) else { return nil }
                return .keyDown(
                    observedAt: observedAt,
                    hardwareKeyCode: UInt16(rawCode),
                    isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )

            case .flagsChanged:
                let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard rawCode >= 0, rawCode <= Int64(UInt16.max),
                    let hardwareKeyCode = modifierPresses.pressedHardwareKeyCode(
                        for: UInt16(rawCode),
                        flags: event.flags
                    )
                else {
                    return nil
                }
                return .keyDown(
                    observedAt: observedAt,
                    hardwareKeyCode: hardwareKeyCode,
                    isAutoRepeat: false
                )

            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                return .pointerMoved(observedAt: observedAt, point: Self.point(event.location))

            case .leftMouseDown:
                return .pointerButtonDown(
                    observedAt: observedAt,
                    point: Self.point(event.location),
                    button: .left
                )

            case .rightMouseDown:
                return .pointerButtonDown(
                    observedAt: observedAt,
                    point: Self.point(event.location),
                    button: .right
                )

            case .otherMouseDown:
                return .pointerButtonDown(
                    observedAt: observedAt,
                    point: Self.point(event.location),
                    button: .other
                )

            case .scrollWheel:
                return .scroll(
                    observedAt: observedAt,
                    point: Self.point(event.location),
                    deltaX: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                    deltaY: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                )

            default:
                return nil
            }
        }

        private static func point(_ point: CGPoint) -> TransientInputEvent.Point {
            TransientInputEvent.Point(x: point.x, y: point.y)
        }

    }

    /// Owns every platform resource for one generation and closes it as a single unit. The
    /// fallback deinitializer matters when a containing runtime is replaced without an explicit
    /// asynchronous shutdown: the main run loop must not retain an orphaned event tap.
    private final class Session: @unchecked Sendable {
        let id: UInt64
        private let callbackToken: UInt
        private let mailbox: InputEventMailbox
        private let tap: CFMachPort
        private let source: CFRunLoopSource
        private let runLoop: CFRunLoop
        private var isInvalidated = false

        init(
            id: UInt64,
            callbackToken: UInt,
            mailbox: InputEventMailbox,
            tap: CFMachPort,
            source: CFRunLoopSource,
            runLoop: CFRunLoop
        ) {
            self.id = id
            self.callbackToken = callbackToken
            self.mailbox = mailbox
            self.tap = tap
            self.source = source
            self.runLoop = runLoop
        }

        func invalidate() {
            guard !isInvalidated else { return }
            isInvalidated = true

            // Close callback admission before touching the run-loop source. A callback already
            // inside the registry finishes first; every later delivery becomes a no-op.
            MacOSCGEventTapBackend.callbackRegistry.removeValue(for: callbackToken)
            mailbox.stop(sessionID: id)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
        }

        deinit {
            invalidate()
        }
    }

    private final class SessionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Session?

        func store(_ session: Session) {
            lock.withLock { value = session }
        }

        func take() -> Session? {
            lock.withLock {
                defer { value = nil }
                return value
            }
        }
    }

    private let clock: @Sendable () -> Date
    private let mailbox = InputEventMailbox()
    private let tapThread = InputEventTapThread()
    private let sessionLock = NSLock()
    private var session: Session?

    init(
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clock = clock
    }

    func start(
        sessionID: UInt64,
        handler: @escaping @Sendable ([TransientInputEvent]) async -> Void
    ) async throws {
        guard sessionLock.withLock({ session == nil }) else {
            throw MacOSCGEventTapBackendError.alreadyRunning
        }

        let callbackBox = CallbackBox(
            mailbox: mailbox,
            sessionID: sessionID,
            clock: clock
        )
        let installedSession = SessionResult()
        try tapThread.performAndWait { runLoop in
            let callbackToken = Self.callbackRegistry.insert { type, event in
                callbackBox.receive(type: type, event: event)
            }
            // CoreGraphics treats userInfo as opaque. Encoding the monotonic token directly avoids
            // giving the C callback a Swift object address whose lifetime it cannot own.
            let userInfo = UnsafeMutableRawPointer(bitPattern: callbackToken)
            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: Self.eventMask,
                    callback: { _, type, event, userInfo in
                        guard let userInfo else { return Unmanaged.passUnretained(event) }
                        let callbackToken = UInt(bitPattern: userInfo)
                        MacOSCGEventTapBackend.callbackRegistry.withValue(for: callbackToken) {
                            callback in
                            callback(type, event)
                        }
                        return Unmanaged.passUnretained(event)
                    },
                    userInfo: userInfo
                )
            else {
                Self.callbackRegistry.removeValue(for: callbackToken)
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                Self.callbackRegistry.removeValue(for: callbackToken)
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                return
            }
            let session = Session(
                id: sessionID,
                callbackToken: callbackToken,
                mailbox: self.mailbox,
                tap: tap,
                source: source,
                runLoop: runLoop
            )
            self.mailbox.start(sessionID: sessionID, handler: handler)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            installedSession.store(session)
        }
        guard let installedSession = installedSession.take() else {
            throw MacOSCGEventTapBackendError.tapCreationFailed
        }
        sessionLock.withLock { session = installedSession }
    }

    func stop(sessionID: UInt64) async {
        let activeSession = sessionLock.withLock { () -> Session? in
            guard let session, session.id == sessionID else { return nil }
            self.session = nil
            return session
        }
        guard let activeSession else { return }
        try? tapThread.performAndWait { _ in activeSession.invalidate() }
    }

    nonisolated static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .scrollWheel,
        .flagsChanged,
    ].reduce(into: CGEventMask(0)) { mask, type in
        mask |= CGEventMask(1) << type.rawValue
    }
}

/// Reduces a `flagsChanged` event into one physical modifier press, or drops a
/// release. The current modifier flags are inspected only in this callback;
/// the reducer keeps no order, time, text, or combination history and emits
/// only the one existing hardware key code accepted by the accumulator.
struct ModifierKeyPressReducer {
    private var pressedNonLockKeys = Set<UInt16>()

    mutating func pressedHardwareKeyCode(
        for hardwareKeyCode: UInt16,
        flags: CGEventFlags
    ) -> UInt16? {
        if hardwareKeyCode == 57 { return hardwareKeyCode }  // Caps Lock toggles on each press.
        guard let requiredFlag = Self.requiredFlag(for: hardwareKeyCode) else { return nil }
        guard flags.contains(requiredFlag) else {
            pressedNonLockKeys.remove(hardwareKeyCode)
            return nil
        }
        guard pressedNonLockKeys.insert(hardwareKeyCode).inserted else {
            pressedNonLockKeys.remove(hardwareKeyCode)
            return nil
        }
        return hardwareKeyCode
    }

    private static func requiredFlag(for hardwareKeyCode: UInt16) -> CGEventFlags? {
        switch hardwareKeyCode {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }
}
