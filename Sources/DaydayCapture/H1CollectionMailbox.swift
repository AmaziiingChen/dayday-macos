import Foundation

/// A synchronous, lock-protected admission mailbox. Platform callbacks offer
/// work without spawning tasks; one detached drain is the sole consumer.
final class H1CollectionMailbox<Element: Sendable>: @unchecked Sendable {
  enum State: Equatable, Sendable {
    case open
    case boundaryReserved
    case draining
    case failed
    case closed
  }

  enum OrdinaryOffer: Equatable, Sendable {
    case accepted
    case overflow
    case rejected
  }

  enum BoundaryOffer: Equatable, Sendable {
    case accepted
    case duplicate
    case overflow
    case rejected
  }

  enum Poll {
    case work(Element)
    case wait
    case finished
  }

  private let lock = NSLock()
  private let ordinaryCapacity: Int
  private let maximumBoundaryFacts: Int
  private var stateValue: State = .open
  private var ordinary: [Element] = []
  private var boundaries: [Element] = []
  private var terminalBoundary: Element?
  private var inFlight = 0
  private let signalStream: AsyncStream<Void>
  private let signalContinuation: AsyncStream<Void>.Continuation

  init(ordinaryCapacity: Int, maximumBoundaryFacts: Int = 8) {
    precondition(ordinaryCapacity > 0 && maximumBoundaryFacts > 0)
    self.ordinaryCapacity = ordinaryCapacity
    self.maximumBoundaryFacts = maximumBoundaryFacts
    var continuation: AsyncStream<Void>.Continuation?
    signalStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    signalContinuation = continuation!
  }

  var signals: AsyncStream<Void> { signalStream }

  var state: State { lock.withLock { stateValue } }

  func offerOrdinary(_ element: Element) -> OrdinaryOffer {
    let result = lock.withLock { () -> OrdinaryOffer in
      guard stateValue == .open else { return .rejected }
      guard ordinary.count < ordinaryCapacity else { return .overflow }
      ordinary.append(element)
      return .accepted
    }
    if result == .accepted { signalContinuation.yield() }
    return result
  }

  /// Reserves bounded critical metadata independently from ordinary capacity.
  /// Distinct negative facts are retained in arrival order up to the closed
  /// bound; no ordinary payload can consume this reserve.
  func reserveBoundary(
    _ element: Element,
    equivalent: (Element, Element) -> Bool = { _, _ in false }
  ) -> BoundaryOffer {
    let result = lock.withLock { () -> BoundaryOffer in
      guard stateValue == .open || stateValue == .boundaryReserved else { return .rejected }
      if boundaries.contains(where: { equivalent($0, element) }) { return .duplicate }
      guard boundaries.count < maximumBoundaryFacts else { return .overflow }
      boundaries.append(element)
      stateValue = .boundaryReserved
      return .accepted
    }
    if result == .accepted { signalContinuation.yield() }
    return result
  }

  func beginDraining(with boundary: Element) -> Bool {
    let accepted = lock.withLock { () -> Bool in
      switch stateValue {
      case .open, .boundaryReserved:
        terminalBoundary = boundary
        stateValue = .draining
        return true
      case .draining, .failed, .closed:
        return false
      }
    }
    if accepted { signalContinuation.yield() }
    return accepted
  }

  func poll() -> Poll {
    let result = lock.withLock { () -> Poll in
      if !ordinary.isEmpty {
        inFlight += 1
        return .work(ordinary.removeFirst())
      }
      if !boundaries.isEmpty {
        inFlight += 1
        return .work(boundaries.removeFirst())
      }
      if let terminalBoundary {
        self.terminalBoundary = nil
        inFlight += 1
        return .work(terminalBoundary)
      }
      switch stateValue {
      case .draining:
        stateValue = .closed
        return .finished
      case .failed, .closed:
        return .finished
      case .boundaryReserved:
        return .wait
      case .open:
        return .wait
      }
    }
    if case .finished = result { signalContinuation.finish() }
    return result
  }

  func fail() -> [Element] {
    let discarded = lock.withLock { () -> [Element] in
      guard stateValue != .closed else { return [] }
      stateValue = .failed
      var work = ordinary + boundaries
      if let terminalBoundary { work.append(terminalBoundary) }
      ordinary.removeAll()
      boundaries.removeAll()
      terminalBoundary = nil
      return work
    }
    signalContinuation.finish()
    return discarded
  }

  var canReconcile: Bool {
    lock.withLock {
      (stateValue == .open || stateValue == .boundaryReserved)
        && ordinary.isEmpty && boundaries.isEmpty && inFlight == 0
    }
  }

  func reopenAfterSuccessfulReconcile() -> Bool {
    lock.withLock {
      guard stateValue == .boundaryReserved, ordinary.isEmpty, boundaries.isEmpty,
        terminalBoundary == nil, inFlight == 0
      else {
        return stateValue == .open
      }
      stateValue = .open
      return true
    }
  }

  func completeWork() {
    lock.withLock {
      precondition(inFlight > 0)
      inFlight -= 1
    }
    signalContinuation.yield()
  }
}
