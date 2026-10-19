import DaydayCore
import Foundation

public protocol ProviderHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol ProviderConnectionTesting: Sendable {
  func testConnection(
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws
}

public protocol WorkReportGenerating: Sendable {
  func generate(
    context: WorkReportContext,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String,
    writingPreferences: WorkReportWritingPreferences
  ) async throws -> ProviderWorkReportResponse
}

extension WorkReportGenerating {
  func generate(
    context: WorkReportContext,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws -> ProviderWorkReportResponse {
    try await generate(
      context: context,
      configuration: configuration,
      credential: credential,
      writingPreferences: .standard
    )
  }
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport, Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

public struct ProviderWorkReportResponse: Equatable, Sendable {
  public let requestID: String?
  public let content: String
  public let usage: ProviderReportedTokenUsage?
  public let reasoningContentWasPresent: Bool

  public init(
    requestID: String?,
    content: String,
    usage: ProviderReportedTokenUsage?,
    reasoningContentWasPresent: Bool
  ) {
    self.requestID = requestID
    self.content = content
    self.usage = usage
    self.reasoningContentWasPresent = reasoningContentWasPresent
  }
}

/// A credential-free, in-memory representation of the exact report request. The Settings UI may
/// display it, but it is never persisted or logged by the provider client.
public struct WorkReportRequestPreview: Equatable, Sendable {
  public let endpoint: URL
  public let model: String
  public let systemPrompt: String
  public let userMessage: String
  public let contextJSON: String
  public let requestBodyJSON: String

  public init(
    endpoint: URL,
    model: String,
    systemPrompt: String,
    userMessage: String,
    contextJSON: String,
    requestBodyJSON: String
  ) {
    self.endpoint = endpoint
    self.model = model
    self.systemPrompt = systemPrompt
    self.userMessage = userMessage
    self.contextJSON = contextJSON
    self.requestBodyJSON = requestBodyJSON
  }
}

public enum WorkReportProviderError: Error, Equatable, Sendable {
  case invalidEndpoint
  case missingCredential
  case cancelled
  case transportUnavailable
  case unauthorized
  case rateLimited
  case serverFailure(statusCode: Int)
  case rejected(statusCode: Int)
  case invalidResponse
  case emptyReport
  case configuredModelUnavailable
}

/// A purpose-specific OpenAI Chat Completions client. Its public generation API accepts only the
/// closed `WorkReportContext` allowlist, so journal and mood artifacts cannot enter by accident.
public struct OpenAICompatibleWorkReportClient: ProviderConnectionTesting, WorkReportGenerating,
  Sendable
{
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
    context: WorkReportContext,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String,
    writingPreferences: WorkReportWritingPreferences = .standard
  ) async throws -> ProviderWorkReportResponse {
    guard !credential.isEmpty else { throw WorkReportProviderError.missingCredential }
    let messages = try ChineseWorkReportPrompt.makeMessages(
      for: context, writingPreferences: writingPreferences
    )
    let request = try Self.request(
      messages: messages,
      configuration: configuration,
      credential: credential,
      timeout: timeout
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

  public static func preview(
    context: WorkReportContext,
    configuration: OpenAICompatibleProviderConfiguration,
    writingPreferences: WorkReportWritingPreferences = .standard
  ) throws -> WorkReportRequestPreview {
    guard let endpoint = chatCompletionsURL(from: configuration.endpoint) else {
      throw WorkReportProviderError.invalidEndpoint
    }
    let messages = try ChineseWorkReportPrompt.makeMessages(
      for: context,
      writingPreferences: writingPreferences
    )
    let body = requestBody(messages: messages, configuration: configuration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let requestBodyJSON = String(data: try encoder.encode(body), encoding: .utf8) else {
      throw WorkReportProviderError.invalidResponse
    }
    return WorkReportRequestPreview(
      endpoint: endpoint,
      model: configuration.model,
      systemPrompt: messages.system,
      userMessage: messages.user,
      contextJSON: messages.contextJSON,
      requestBodyJSON: requestBodyJSON
    )
  }

  /// Verifies credentials and model availability without sending work context or user content.
  public func testConnection(
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws {
    guard !credential.isEmpty else { throw WorkReportProviderError.missingCredential }
    guard let endpoint = Self.modelsURL(from: configuration.endpoint) else {
      throw WorkReportProviderError.invalidEndpoint
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = min(timeout, 30)
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await transport.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw WorkReportProviderError.invalidResponse
      }
      try Self.validate(statusCode: http.statusCode)
      let models: ModelsResponse
      do {
        models = try JSONDecoder().decode(ModelsResponse.self, from: data)
      } catch {
        throw WorkReportProviderError.invalidResponse
      }
      guard models.data.contains(where: { $0.id == configuration.model }) else {
        throw WorkReportProviderError.configuredModelUnavailable
      }
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

  static func request(
    messages: ChineseWorkReportPrompt.Messages,
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String,
    timeout: TimeInterval
  ) throws -> URLRequest {
    guard let endpoint = chatCompletionsURL(from: configuration.endpoint),
      timeout.isFinite, timeout > 0,
      !credential.isEmpty,
      !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw WorkReportProviderError.invalidEndpoint }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(
      requestBody(messages: messages, configuration: configuration)
    )
    return request
  }

  private static func requestBody(
    messages: ChineseWorkReportPrompt.Messages,
    configuration: OpenAICompatibleProviderConfiguration
  ) -> RequestBody {
    RequestBody(
      model: configuration.model,
      messages: [
        .init(role: "system", content: messages.system),
        .init(role: "user", content: messages.user),
      ],
      stream: false,
      maxTokens: 4_096,
      thinking: .init(type: configuration.thinkingEnabled ? "enabled" : "disabled"),
      reasoningEffort: configuration.thinkingEnabled
        ? configuration.reasoningEffort.rawValue
        : nil
    )
  }

  private static func chatCompletionsURL(from base: URL) -> URL? {
    guard var components = validatedComponents(from: base) else { return nil }

    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/chat/completions") {
      components.path = path
    } else if path.hasSuffix("/v1") {
      components.path = path + "/chat/completions"
    } else if path.isEmpty || path == "/" {
      components.path = "/v1/chat/completions"
    } else {
      components.path = path + "/v1/chat/completions"
    }
    return components.url
  }

  private static func modelsURL(from base: URL) -> URL? {
    guard var components = validatedComponents(from: base) else { return nil }
    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/chat/completions") {
      path = String(path.dropLast("/chat/completions".count))
    }
    if path.hasSuffix("/v1") {
      components.path = path + "/models"
    } else if path.isEmpty || path == "/" {
      components.path = "/v1/models"
    } else {
      components.path = path + "/v1/models"
    }
    return components.url
  }

  private static func validatedComponents(from base: URL) -> URLComponents? {
    guard let components = URLComponents(url: base, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      scheme == "https" || (scheme == "http" && isLoopback(host))
    else { return nil }
    return components
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private static func decode(data: Data, response: URLResponse) throws
    -> ProviderWorkReportResponse
  {
    guard let http = response as? HTTPURLResponse else {
      throw WorkReportProviderError.invalidResponse
    }
    try validate(statusCode: http.statusCode)

    let decoded: ResponseBody
    do {
      decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
    } catch {
      throw WorkReportProviderError.invalidResponse
    }
    guard let message = decoded.choices.first?.message else {
      throw WorkReportProviderError.invalidResponse
    }
    let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw WorkReportProviderError.emptyReport }
    return ProviderWorkReportResponse(
      requestID: decoded.id,
      content: content,
      usage: decoded.usage.map {
        ProviderReportedTokenUsage(
          promptTokens: $0.promptTokens,
          completionTokens: $0.completionTokens,
          totalTokens: $0.totalTokens,
          cachedTokens: $0.promptTokensDetails?.cachedTokens
        )
      },
      reasoningContentWasPresent: message.reasoningContent?.isEmpty == false
    )
  }

  private static func validate(statusCode: Int) throws {
    switch statusCode {
    case 200...299:
      return
    case 401, 403:
      throw WorkReportProviderError.unauthorized
    case 429:
      throw WorkReportProviderError.rateLimited
    case 500...599:
      throw WorkReportProviderError.serverFailure(statusCode: statusCode)
    default:
      throw WorkReportProviderError.rejected(statusCode: statusCode)
    }
  }
}

private struct RequestBody: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }
  struct Thinking: Encodable {
    let type: String
  }

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
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String
      let reasoningContent: String?

      enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
      }
    }
    let message: Message
  }

  struct Usage: Decodable {
    struct PromptTokensDetails: Decodable {
      let cachedTokens: Int?

      enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
      }
    }

    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptTokensDetails: PromptTokensDetails?

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

private struct ModelsResponse: Decodable {
  struct Model: Decodable {
    let id: String
  }

  let data: [Model]
}
