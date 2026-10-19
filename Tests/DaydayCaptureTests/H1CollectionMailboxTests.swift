import Testing

@testable import DaydayCapture

@Suite("H1 synchronous collection mailbox")
struct H1CollectionMailboxTests {
  @Test("five states preserve the critical reserve and reject post-boundary ordinary work")
  func fiveStateAdmission() {
    let mailbox = H1CollectionMailbox<String>(ordinaryCapacity: 1)
    #expect(mailbox.state == .open)
    #expect(mailbox.offerOrdinary("A") == .accepted)
    #expect(mailbox.offerOrdinary("overflow") == .overflow)
    #expect(mailbox.reserveBoundary("B") == .accepted)
    #expect(mailbox.state == .boundaryReserved)
    #expect(mailbox.offerOrdinary("C") == .rejected)

    guard case .work("A") = mailbox.poll() else {
      Issue.record("ordinary FIFO item was not first")
      return
    }
    mailbox.completeWork()
    guard case .work("B") = mailbox.poll() else {
      Issue.record("reserved boundary was not retained")
      return
    }
    mailbox.completeWork()
    guard case .wait = mailbox.poll() else {
      Issue.record("drained boundary must await an explicit safe reopen")
      return
    }
    #expect(mailbox.state == .boundaryReserved)
    #expect(mailbox.reopenAfterSuccessfulReconcile())
    #expect(mailbox.state == .open)

    #expect(mailbox.beginDraining(with: "shutdown"))
    #expect(mailbox.state == .draining)
    guard case .work("shutdown") = mailbox.poll() else {
      Issue.record("shutdown boundary was not drained")
      return
    }
    mailbox.completeWork()
    guard case .finished = mailbox.poll() else {
      Issue.record("draining mailbox did not finish")
      return
    }
    #expect(mailbox.state == .closed)
    #expect(mailbox.offerOrdinary("late") == .rejected)

    let failed = H1CollectionMailbox<Int>(ordinaryCapacity: 1)
    #expect(failed.offerOrdinary(1) == .accepted)
    #expect(failed.fail() == [1])
    #expect(failed.state == .failed)
    #expect(failed.offerOrdinary(2) == .rejected)
  }

  @Test("critical reserve deduplicates equivalent facts and reports saturation explicitly")
  func criticalReserveIsBoundedAndExplicit() {
    let mailbox = H1CollectionMailbox<String>(ordinaryCapacity: 1, maximumBoundaryFacts: 8)
    #expect(
      mailbox.reserveBoundary("same", equivalent: { $0 == $1 }) == .accepted
    )
    #expect(
      mailbox.reserveBoundary("same", equivalent: { $0 == $1 }) == .duplicate
    )
    for index in 1..<8 {
      #expect(mailbox.reserveBoundary("boundary-\(index)") == .accepted)
    }
    #expect(mailbox.reserveBoundary("ninth-distinct") == .overflow)
    #expect(mailbox.state == .boundaryReserved)

    #expect(mailbox.beginDraining(with: "terminal"))
    var drained: [String] = []
    while true {
      switch mailbox.poll() {
      case .work(let value):
        drained.append(value)
        mailbox.completeWork()
      case .wait:
        Issue.record("draining mailbox unexpectedly waited")
        return
      case .finished:
        #expect(drained.count == 9)
        #expect(drained.first == "same")
        #expect(drained.last == "terminal")
        return
      }
    }
  }
}
