import DaydayCore
import Foundation

public protocol JournalAIGenerating: Sendable {
  func generate(
    markdown: String,
    operation: JournalDerivedOperation,
    customInstruction: String?,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws -> ProviderJournalAIResponse
}

public struct ProviderJournalAIResponse: Equatable, Sendable {
  public let requestID: String?
  public let content: String
  public let usage: ProviderReportedTokenUsage?

  public init(requestID: String?, content: String, usage: ProviderReportedTokenUsage?) {
    self.requestID = requestID
    self.content = content
    self.usage = usage
  }
}

public struct OpenAICompatibleJournalClient: JournalAIGenerating, Sendable {
  public static let promptVersion = "journal-markdown-v1"

  private let transport: any ProviderHTTPTransport
  private let timeout: TimeInterval

  public init(
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
    timeout: TimeInterval = 120
  ) {
    self.transport = transport
    self.timeout = timeout
  }

  public func generate(
    markdown: String,
    operation: JournalDerivedOperation,
    customInstruction: String?,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws -> ProviderJournalAIResponse {
    guard !credential.isEmpty else { throw WorkReportProviderError.missingCredential }
    let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WorkReportProviderError.emptyReport }
    guard let endpoint = Self.chatCompletionsURL(from: configuration.endpoint) else {
      throw WorkReportProviderError.invalidEndpoint
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(
      RequestBody(
        model: configuration.model,
        messages: [
          .init(role: "system", content: Self.systemPrompt),
          .init(
            role: "user",
            content: Self.userPrompt(
              markdown: markdown,
              operation: operation,
              customInstruction: customInstruction
            )
          ),
        ],
        stream: false,
        maxTokens: 8_192,
        thinking: .init(type: configuration.thinkingEnabled ? "enabled" : "disabled"),
        reasoningEffort: configuration.thinkingEnabled
          ? configuration.reasoningEffort.rawValue : nil
      )
    )

    do {
      let (data, response) = try await transport.data(for: request)
      return try Self.decode(data: data, response: response)
    } catch is CancellationError {
      throw WorkReportProviderError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw WorkReportProviderError.cancelled
    } catch let error as WorkReportProviderError {
      throw error
    } catch {
      throw WorkReportProviderError.transportUnavailable
    }
  }

  static let systemPrompt = """
    你是 Dayday 日记的 Markdown 编辑助手。只处理用户明确提供的日记正文。
    必须返回完整的 Markdown 正文，不要解释，不要添加代码围栏，不要虚构事实、经历、地点、人物或情绪。
    保留图片链接、链接目标、列表层级、任务列表、表格与其他有效 Markdown 结构。
    """

  static func userPrompt(
    markdown: String,
    operation: JournalDerivedOperation,
    customInstruction: String?
  ) -> String {
    let instruction: String = switch operation {
    case .organize:
      "整理结构与段落，使内容更清晰；保持原意与事实不变。"
    case .rewrite:
      "改善表达、节奏与可读性；保持原意、事实和个人语气。"
    case .continueWriting:
      "沿着现有内容自然续写；保留全部原文，并在末尾续写，不要代替用户编造具体事实。"
    case .proofread:
      "仅校对错别字、标点、病句和 Markdown 格式；尽量少改。"
    }
    let custom = customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
    return """
      操作：\(instruction)
      \(custom.map { "补充要求：\($0)" } ?? "")

      原始 Markdown：
      <journal>
      \(markdown)
      </journal>
      """
  }

  private static func chatCompletionsURL(from base: URL) -> URL? {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
      scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { return nil }
    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/chat/completions") { components.path = path }
    else if path.hasSuffix("/v1") { components.path = path + "/chat/completions" }
    else if path.isEmpty || path == "/" { components.path = "/v1/chat/completions" }
    else { components.path = path + "/v1/chat/completions" }
    return components.url
  }

  private static func decode(data: Data, response: URLResponse) throws -> ProviderJournalAIResponse {
    guard let http = response as? HTTPURLResponse else {
      throw WorkReportProviderError.invalidResponse
    }
    switch http.statusCode {
    case 200...299: break
    case 401, 403: throw WorkReportProviderError.unauthorized
    case 429: throw WorkReportProviderError.rateLimited
    case 500...599: throw WorkReportProviderError.serverFailure(statusCode: http.statusCode)
    default: throw WorkReportProviderError.rejected(statusCode: http.statusCode)
    }
    guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
      let message = decoded.choices.first?.message.content
    else { throw WorkReportProviderError.invalidResponse }
    let content = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw WorkReportProviderError.emptyReport }
    return ProviderJournalAIResponse(
      requestID: decoded.id,
      content: content,
      usage: decoded.usage.map {
        ProviderReportedTokenUsage(
          promptTokens: $0.promptTokens,
          completionTokens: $0.completionTokens,
          totalTokens: $0.totalTokens,
          cachedTokens: $0.promptTokensDetails?.cachedTokens
        )
      }
    )
  }
}

private struct RequestBody: Encodable {
  struct Message: Encodable { let role: String; let content: String }
  struct Thinking: Encodable { let type: String }
  let model: String
  let messages: [Message]
  let stream: Bool
  let maxTokens: Int
  let thinking: Thinking
  let reasoningEffort: String?
  enum CodingKeys: String, CodingKey {
    case model, messages, stream, thinking
    case maxTokens = "max_tokens"
    case reasoningEffort = "reasoning_effort"
  }
}

private struct ResponseBody: Decodable {
  struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
  struct Usage: Decodable {
    struct Details: Decodable {
      let cachedTokens: Int?
      enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptTokensDetails: Details?
    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
      case promptTokensDetails = "prompt_tokens_details"
    }
  }
  let id: String?
  let choices: [Choice]
  let usage: Usage?
}
