import DaydayCore
@preconcurrency import Dispatch
import Foundation
import Network
import Security

/// Local-only network primitives for the health archive. Bonjour is discovery only: the TXT
/// record is empty, all payloads travel over TLS 1.3 with the user-created pairing secret, and
/// the listener accepts a single bounded archive batch per connection.
public enum HealthLocalSync {
  public static let bonjourServiceType = "_dayday-health._tcp"
  public static let maximumFrameBytes = 8 * 1024 * 1024
  static let transferDeadline: DispatchTimeInterval = .seconds(30)
}

public struct HealthPairingCredential: Codable, Hashable, Sendable {
  public enum Error: Swift.Error, Equatable, Sendable { case invalidSecret }

  public let installationID: UUID
  public let secret: Data

  public init(installationID: UUID = UUID(), secret: Data) throws {
    guard secret.count == 32 else { throw Error.invalidSecret }
    self.installationID = installationID
    self.secret = secret
  }

  public static func generate() throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw HealthLocalSyncError.randomnessUnavailable
    }
    return try Self(secret: Data(bytes))
  }

  /// A single pasteable local-only setup string. It is deliberately not logged or added to a
  /// Bonjour record. Revoke it on either device to require a fresh pairing.
  public var setupCode: String {
    "dayday-health://pair/\(installationID.uuidString.lowercased())/\(secret.base64URLEncodedString())"
  }

  public init(setupCode: String) throws {
    let parts = setupCode.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 4, parts[0] == "dayday-health:", parts[1] == "pair",
      let installationID = UUID(uuidString: String(parts[2])),
      let secret = Data(base64URLEncoded: String(parts[3]))
    else { throw Error.invalidSecret }
    try self.init(installationID: installationID, secret: secret)
  }
}

public enum HealthLocalSyncError: LocalizedError, Equatable, Sendable {
  case randomnessUnavailable
  case invalidFrame
  case frameTooLarge
  case unexpectedAcknowledgement
  case transportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .randomnessUnavailable: "无法生成本机配对凭据。"
    case .invalidFrame: "收到的健康同步数据包无效。"
    case .frameTooLarge: "健康同步数据包超过本机安全上限。"
    case .unexpectedAcknowledgement: "收到的同步确认与发送批次不一致。"
    case let .transportFailed(message): "局域网健康同步失败：\(message)"
    }
  }
}

/// A single paired iPhone is expected to stream bounded batches sequentially. Rejecting a second
/// connection while one archive transaction is active is deliberate backpressure: it prevents
/// duplicate decoding and concurrent SQLite work without keeping a polling worker alive.
final class HealthLocalSyncConnectionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var active: (token: UUID, cancel: @Sendable () -> Void)?

  func acquire(cancel: @escaping @Sendable () -> Void) -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    guard active == nil else { return nil }
    let token = UUID()
    active = (token, cancel)
    return token
  }

  func release(_ token: UUID) {
    lock.lock()
    defer { lock.unlock() }
    guard active?.token == token else { return }
    active = nil
  }

  func cancelActive() {
    lock.lock()
    let cancellation = active?.cancel
    lock.unlock()
    cancellation?()
  }
}

/// Listener callbacks and archive writes can outlive a stop/start edge. A generation makes those
/// callbacks observationally inert while the connection gate keeps the old archive transaction
/// admitted until its detached task actually exits.
final class HealthLocalSyncLifecycle: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var isRunning = false

  func begin() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    isRunning = true
    return generation
  }

  func stop() {
    lock.lock()
    generation &+= 1
    isRunning = false
    lock.unlock()
  }

  func isActive(_ candidate: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isRunning && generation == candidate
  }
}

/// A small generic-password Keychain wrapper so health pairing material never lands in
/// preferences, the health SQLite file, diagnostics, or source control.
public struct HealthPairingCredentialStore: Sendable {
  public let service: String

  public init(service: String = "app.dayday.health-local-pairing") { self.service = service }

  public func load() throws -> HealthPairingCredential? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw HealthLocalSyncError.transportFailed("无法读取本机配对凭据（\(status)）。")
    }
    return try JSONDecoder().decode(HealthPairingCredential.self, from: data)
  }

  public func save(_ credential: HealthPairingCredential) throws {
    let value = try JSONEncoder().encode(credential)
    let query = baseQuery()
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw HealthLocalSyncError.transportFailed("无法保存本机配对凭据（\(updateStatus)）。")
    }
    var insert = query
    insert[kSecValueData as String] = value
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw HealthLocalSyncError.transportFailed("无法保存本机配对凭据（\(insertStatus)）。")
    }
  }

  public func remove() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw HealthLocalSyncError.transportFailed("无法移除本机配对凭据（\(status)）。")
    }
  }

  private func baseQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: "default"]
  }
}

public final class HealthLocalSyncServer: @unchecked Sendable {
  /// Listener state, intentionally free of endpoint, health-fact, and credential details.
  public enum State: Equatable, Sendable { case stopped, starting, ready, failed }

  /// A privacy-safe view of the most recent local transfer. It deliberately contains no peer
  /// address, HealthKit values, source names, pairing material, or raw transport error.
  public enum TransferState: Equatable, Sendable {
    case waitingForCompanion
    case receiving
    case persisted(observationCount: Int, tombstoneCount: Int, at: Date)
    case incomplete
  }

  private let archive: any HealthArchiveRepository
  private let queue = DispatchQueue(label: "app.dayday.health-local-sync-server", qos: .utility)
  private let connectionGate = HealthLocalSyncConnectionGate()
  private let lifecycle = HealthLocalSyncLifecycle()
  private var listener: NWListener?
  public var stateUpdateHandler: ((State) -> Void)?
  public var transferUpdateHandler: ((TransferState) -> Void)?

  public init(archive: any HealthArchiveRepository) { self.archive = archive }

  public func start(using credential: HealthPairingCredential) throws {
    stop()
    let listener = try NWListener(using: .tcpParameters(credential: credential))
    let generation = lifecycle.begin()
    listener.service = .init(name: nil, type: HealthLocalSync.bonjourServiceType, domain: nil, txtRecord: nil)
    listener.stateUpdateHandler = { [weak self] state in
      guard let self, self.lifecycle.isActive(generation) else { return }
      switch state {
      case .ready: self.publish(.ready)
      case .failed: self.publish(.failed)
      case .cancelled: self.publish(.stopped)
      default: self.publish(.starting)
      }
    }
    listener.newConnectionHandler = { [weak self, archive, queue] connection in
      guard let self else {
        connection.cancel()
        return
      }
      guard self.lifecycle.isActive(generation) else {
        connection.cancel()
        return
      }
      guard let token = self.connectionGate.acquire(cancel: { connection.cancel() }) else {
        connection.cancel()
        return
      }
      connection.start(queue: queue)
      let timeout = DispatchWorkItem { connection.cancel() }
      queue.asyncAfter(deadline: .now() + HealthLocalSync.transferDeadline, execute: timeout)
      Task.detached(priority: .utility) {
        defer {
          timeout.cancel()
          connection.cancel()
          self.connectionGate.release(token)
        }
        do {
          guard self.lifecycle.isActive(generation) else { return }
          self.publishTransfer(.receiving)
          let frame = try await connection.receiveHealthFrame()
          let batch = try JSONDecoder().decode(HealthArchiveBatch.self, from: frame)
          _ = try await archive.apply(batch)
          guard self.lifecycle.isActive(generation) else { return }
          self.publishTransfer(.persisted(
            observationCount: batch.observations.count,
            tombstoneCount: batch.tombstones.count,
            at: .now
          ))
          let acknowledgement = HealthSyncAcknowledgement(
            sourceInstallationID: batch.sourceInstallationID, batchID: batch.batchID, receivedAt: .now
          )
          try await connection.sendHealthFrame(JSONEncoder().encode(acknowledgement))
        } catch {
          // Content and pairing secret are never included in the error or a log. Closing the
          // connection leaves the iPhone's persisted batch pending for a later retry.
          guard self.lifecycle.isActive(generation) else { return }
          self.publishTransfer(.incomplete)
        }
      }
    }
    self.listener = listener
    publish(.starting)
    publishTransfer(.waitingForCompanion)
    listener.start(queue: queue)
  }

  public func stop() {
    lifecycle.stop()
    listener?.cancel()
    listener = nil
    connectionGate.cancelActive()
    publish(.stopped)
  }

  private func publish(_ state: State) { stateUpdateHandler?(state) }
  private func publishTransfer(_ state: TransferState) { transferUpdateHandler?(state) }
}

private extension NWParameters {
  static func tcpParameters(credential: HealthPairingCredential) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let secret = ownedDispatchData(credential.secret)
    let identity = ownedDispatchData(Data(credential.installationID.uuidString.lowercased().utf8))
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret, identity)
    return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
  }

  private static func ownedDispatchData(_ data: Data) -> dispatch_data_t {
    let dispatchData: DispatchData = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      DispatchData(bytes: bytes)
    }
    return dispatchData._bridgeToObjectiveC()
  }
}

private extension NWConnection {
  func receiveHealthFrame() async throws -> Data {
    let header = try await receiveExactly(4)
    let size = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    guard size > 0 else { throw HealthLocalSyncError.invalidFrame }
    guard size <= HealthLocalSync.maximumFrameBytes else { throw HealthLocalSyncError.frameTooLarge }
    return try await receiveExactly(Int(size))
  }

  func sendHealthFrame(_ data: Data) async throws {
    guard data.count <= HealthLocalSync.maximumFrameBytes else { throw HealthLocalSyncError.frameTooLarge }
    var length = UInt32(data.count).bigEndian
    let frame = withUnsafeBytes(of: &length) { Data($0) } + data
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      send(content: frame, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: HealthLocalSyncError.transportFailed(error.localizedDescription)) }
        else { continuation.resume() }
      })
    }
  }

  private func receiveExactly(_ length: Int) async throws -> Data {
    var output = Data()
    while output.count < length {
      let next = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        receive(minimumIncompleteLength: 1, maximumLength: length - output.count) { data, _, complete, error in
          if let error { continuation.resume(throwing: HealthLocalSyncError.transportFailed(error.localizedDescription)) }
          else if let data, !data.isEmpty { continuation.resume(returning: data) }
          else if complete { continuation.resume(throwing: HealthLocalSyncError.invalidFrame) }
          else { continuation.resume(throwing: HealthLocalSyncError.invalidFrame) }
        }
      }
      output.append(next)
    }
    return output
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    self.init(base64Encoded: base64)
  }
}
