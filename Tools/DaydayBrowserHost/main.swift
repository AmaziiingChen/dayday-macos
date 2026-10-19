import Foundation

private struct BrowserMessage: Decodable {
  let protocolVersion: Int
  let sequence: UInt64
  let bridgeReady: Bool
  let incognito: Bool
}

private struct BrowserSafetyState: Encodable {
  let protocolVersion: Int
  let browserBundleIdentifier: String
  let sequence: UInt64
  let bridgeReady: Bool
  let incognito: Bool
  let observedAt: Date
}

private struct HostReply: Encodable {
  let accepted: Bool
  let sequence: UInt64?
}

private let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--browser-bundle-id"),
  arguments.indices.contains(flag + 1)
else { exit(64) }
let bundleIdentifier = arguments[flag + 1].lowercased()
let allowed = ["com.google.chrome", "com.tab-browser.tabbit"]
guard allowed.contains(bundleIdentifier) else { exit(64) }

let fileManager = FileManager.default
let directory: URL
if let stateDirectoryFlag = arguments.firstIndex(of: "--state-directory"),
  arguments.indices.contains(stateDirectoryFlag + 1)
{
  directory = URL(fileURLWithPath: arguments[stateDirectoryFlag + 1], isDirectory: true)
} else {
  let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  directory = applicationSupport
    .appendingPathComponent("Dayday", isDirectory: true)
    .appendingPathComponent("BrowserBridge", isDirectory: true)
}
try fileManager.createDirectory(
  at: directory,
  withIntermediateDirectories: true,
  attributes: [.posixPermissions: 0o700]
)
let stateURL = directory.appendingPathComponent("\(bundleIdentifier).json")
var lastSequence: UInt64 = 0

private func readFrame() -> Data? {
  func readExactly(_ length: Int) -> Data? {
    var data = Data()
    while data.count < length {
      let chunk = FileHandle.standardInput.readData(ofLength: length - data.count)
      guard !chunk.isEmpty else { return nil }
      data.append(chunk)
    }
    return data
  }
  guard let header = readExactly(4) else { return nil }
  guard header.count == 4 else { return nil }
  let length = header.withUnsafeBytes { bytes in
    UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
  }
  guard length > 0, length <= 64 * 1024 else { return nil }
  return readExactly(Int(length))
}

private func writeReply(_ reply: HostReply) {
  guard let payload = try? JSONEncoder().encode(reply), payload.count <= Int(UInt32.max) else {
    return
  }
  var length = UInt32(payload.count).littleEndian
  let header = Data(bytes: &length, count: 4)
  try? FileHandle.standardOutput.write(contentsOf: header + payload)
}

while let frame = readFrame() {
  guard let object = try? JSONSerialization.jsonObject(with: frame, options: []),
    let dictionary = object as? [String: Any],
    Set(dictionary.keys) == Set(["protocolVersion", "sequence", "bridgeReady", "incognito"]),
    let message = try? JSONDecoder().decode(BrowserMessage.self, from: frame),
    message.protocolVersion == 1,
    message.bridgeReady,
    message.sequence > lastSequence
  else {
    writeReply(HostReply(accepted: false, sequence: nil))
    continue
  }
  lastSequence = message.sequence
  let state = BrowserSafetyState(
    protocolVersion: 1,
    browserBundleIdentifier: bundleIdentifier,
    sequence: message.sequence,
    bridgeReady: message.bridgeReady,
    incognito: message.incognito,
    observedAt: Date()
  )
  do {
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  } catch {
    writeReply(HostReply(accepted: false, sequence: message.sequence))
    continue
  }
  writeReply(HostReply(accepted: true, sequence: message.sequence))
}
