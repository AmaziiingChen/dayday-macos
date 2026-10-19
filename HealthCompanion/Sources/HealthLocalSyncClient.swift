@preconcurrency import Dispatch
import Foundation
import Network
import Security

private enum HealthCompanionLocalSync {
    static let bonjourServiceType = "_dayday-health._tcp"
    static let maximumFrameBytes = 8 * 1024 * 1024
    static let discoveryTimeout: DispatchTimeInterval = .seconds(12)
    static let transferDeadline: DispatchTimeInterval = .seconds(30)
}

struct HealthCompanionPairingCredential: Codable, Sendable {
    enum Error: Swift.Error { case invalidSetupCode }

    let installationID: UUID
    let secret: Data

    init(setupCode: String) throws {
        let parts = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "dayday-health:", parts[1] == "pair",
              let installationID = UUID(uuidString: String(parts[2])),
              let secret = Data(base64URLEncoded: String(parts[3])), secret.count == 32 else {
            throw Error.invalidSetupCode
        }
        self.installationID = installationID
        self.secret = secret
    }
}

struct HealthCompanionPairingStore: Sendable {
    private let service = "app.dayday.health-local-pairing"

    func load() throws -> HealthCompanionPairingCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HealthCompanionSyncError.keychain(status)
        }
        return try JSONDecoder().decode(HealthCompanionPairingCredential.self, from: data)
    }

    func save(_ credential: HealthCompanionPairingCredential) throws {
        let value = try JSONEncoder().encode(credential)
        let query = baseQuery()
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw HealthCompanionSyncError.keychain(updateStatus) }
        var insert = query
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw HealthCompanionSyncError.keychain(status) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HealthCompanionSyncError.keychain(status) }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "default"]
    }
}

protocol HealthCompanionPairingStoring: Sendable {
    func load() throws -> HealthCompanionPairingCredential?
    func save(_ credential: HealthCompanionPairingCredential) throws
    func remove() throws
}

extension HealthCompanionPairingStore: HealthCompanionPairingStoring {}

enum HealthCompanionSyncError: LocalizedError {
    case invalidFrame
    case frameTooLarge
    case acknowledgementMismatch
    case keychain(OSStatus)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "Mac 返回的同步数据无效。"
        case .frameTooLarge: "本次健康同步批次过大。"
        case .acknowledgementMismatch: "Mac 返回的确认不属于当前同步批次。"
        case let .keychain(status): "无法读取本机配对凭据（\(status)）。"
        case let .transport(message): "局域网同步失败：\(message)"
        }
    }
}

private final class HealthBrowserContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint, Error>?

    init(_ continuation: CheckedContinuation<NWEndpoint, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<NWEndpoint, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// The companion makes one bounded TLS connection for one already-persisted batch. A failed
/// attempt deliberately does not mutate queue state; only a matching Mac acknowledgement does.
protocol HealthLocalSyncing: AnyObject, Sendable {
    func transfer(
        _ batch: HealthArchiveBatch,
        credential: HealthCompanionPairingCredential,
        completion: @escaping @MainActor (Result<HealthSyncAcknowledgement, Error>) -> Void
    )
    func resetEndpointCache()
}

final class HealthLocalSyncClient: HealthLocalSyncing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.dayday.health-companion.local-sync", qos: .utility)
    private let endpointLock = NSLock()
    private var cachedEndpoint: (endpoint: NWEndpoint, expiresAt: Date)?

    func transfer(
        _ batch: HealthArchiveBatch,
        credential: HealthCompanionPairingCredential,
        completion: @escaping @MainActor (Result<HealthSyncAcknowledgement, Error>) -> Void
    ) {
        queue.async {
            Task {
                let result: Result<HealthSyncAcknowledgement, Error>
                do {
                    result = .success(try await self.transfer(batch, credential: credential))
                } catch {
                    result = .failure(error)
                }
                await MainActor.run { completion(result) }
            }
        }
    }

    func resetEndpointCache() {
        clearCachedEndpoint()
    }

    private func transfer(
        _ batch: HealthArchiveBatch,
        credential: HealthCompanionPairingCredential
    ) async throws -> HealthSyncAcknowledgement {
        let parameters = NWParameters.tcpParameters(credential: credential)
        let endpoint = try await resolvedEndpoint(using: parameters)
        do {
            let connection = NWConnection(to: endpoint, using: parameters)
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(
                deadline: .now() + HealthCompanionLocalSync.transferDeadline,
                execute: timeout
            )
            defer {
                timeout.cancel()
                connection.cancel()
            }
            try await connection.waitUntilReady()

            try await connection.sendHealthFrame(JSONEncoder().encode(batch))
            let response = try await connection.receiveHealthFrame()
            let acknowledgement = try JSONDecoder().decode(HealthSyncAcknowledgement.self, from: response)
            guard acknowledgement.sourceInstallationID == batch.sourceInstallationID,
                  acknowledgement.batchID == batch.batchID else {
                throw HealthCompanionSyncError.acknowledgementMismatch
            }
            return acknowledgement
        } catch {
            // A cached Bonjour endpoint is only an optimization for a contiguous sync session.
            // Network changes fail the current durable batch and invalidate the hint, so the next
            // explicit/background opportunity performs fresh discovery instead of polling.
            clearCachedEndpoint()
            throw error
        }
    }

    private func resolvedEndpoint(using parameters: NWParameters) async throws -> NWEndpoint {
        let now = Date()
        let cachedEndpoint = endpointLock.withLock { () -> NWEndpoint? in
            guard let cached = self.cachedEndpoint, cached.expiresAt > now else {
                self.cachedEndpoint = nil
                return nil
            }
            return cached.endpoint
        }
        if let cachedEndpoint { return cachedEndpoint }

        let discovered = try await browseFirstEndpoint(using: parameters)
        endpointLock.withLock {
            self.cachedEndpoint = (discovered, now.addingTimeInterval(120))
        }
        return discovered
    }

    private func clearCachedEndpoint() {
        endpointLock.withLock { cachedEndpoint = nil }
    }

    private func browseFirstEndpoint(using parameters: NWParameters) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
            let browser = NWBrowser(
                for: .bonjour(type: HealthCompanionLocalSync.bonjourServiceType, domain: nil),
                using: parameters
            )
            let result = HealthBrowserContinuation(continuation)
            let timeout = DispatchWorkItem {
                browser.cancel()
                result.finish(.failure(HealthCompanionSyncError.transport("未在 12 秒内找到已配对的 Mac。确认两台设备在同一 Wi‑Fi 后重试。")))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case let .failed(error):
                    timeout.cancel()
                    browser.cancel()
                    result.finish(.failure(HealthCompanionSyncError.transport(error.localizedDescription)))
                case .cancelled:
                    timeout.cancel()
                    result.finish(.failure(HealthCompanionSyncError.transport("未找到已配对的 Mac。")))
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if let endpoint = results.first?.endpoint {
                    timeout.cancel()
                    browser.cancel()
                    result.finish(.success(endpoint))
                }
            }
            browser.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + HealthCompanionLocalSync.discoveryTimeout, execute: timeout)
        }
    }
}

private extension NWParameters {
    static func tcpParameters(credential: HealthCompanionPairingCredential) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            dispatchData(credential.secret),
            dispatchData(Data(credential.installationID.uuidString.lowercased().utf8))
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func dispatchData(_ data: Data) -> dispatch_data_t {
        let value: DispatchData = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            DispatchData(bytes: bytes)
        }
        return value._bridgeToObjectiveC()
    }
}

private extension NWConnection {
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: HealthCompanionSyncError.transport(error.localizedDescription))
                case .cancelled:
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: HealthCompanionSyncError.transport("连接已取消。"))
                default: break
                }
            }
        }
    }

    func receiveHealthFrame() async throws -> Data {
        let header = try await receiveExactly(4)
        let size = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard size > 0 else { throw HealthCompanionSyncError.invalidFrame }
        guard size <= HealthCompanionLocalSync.maximumFrameBytes else { throw HealthCompanionSyncError.frameTooLarge }
        return try await receiveExactly(Int(size))
    }

    func sendHealthFrame(_ data: Data) async throws {
        guard data.count <= HealthCompanionLocalSync.maximumFrameBytes else { throw HealthCompanionSyncError.frameTooLarge }
        var length = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: HealthCompanionSyncError.transport(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        var output = Data()
        while output.count < length {
            let next = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                receive(minimumIncompleteLength: 1, maximumLength: length - output.count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: HealthCompanionSyncError.transport(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: HealthCompanionSyncError.invalidFrame) }
                    else { continuation.resume(throwing: HealthCompanionSyncError.invalidFrame) }
                }
            }
            output.append(next)
        }
        return output
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}
