import DaydayAI
import DaydayCore
import Foundation
import Testing

struct OpenAICompatibleJournalClientTests {
  @Test("journal request preserves Markdown and returns the full derived body")
  func requestAndResponse() async throws {
    let transport = JournalRecordingTransport(
      data: Data(
        """
        {"id":"journal-1","choices":[{"message":{"content":"# 整理后\\n\\n- 一项"}}],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20}}
        """.utf8
      )
    )
    let client = OpenAICompatibleJournalClient(transport: transport)
    let response = try await client.generate(
      markdown: "# 原文\n\n- 一项",
      operation: .organize,
      customInstruction: "保持简洁",
      configuration: .deepSeekDefault,
      credential: "test-key"
    )

    #expect(response.requestID == "journal-1")
    #expect(response.content == "# 整理后\n\n- 一项")
    let request = try #require(await transport.request)
    #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["max_tokens"] as? Int == 8_192)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let system = try #require(messages.first?["content"] as? String)
    let user = try #require(messages.last?["content"] as? String)
    #expect(system.contains("返回完整的 Markdown 正文"))
    #expect(system.contains("不要虚构事实"))
    #expect(user.contains("保持简洁"))
    #expect(user.contains("# 原文"))
  }

  @Test("remote plaintext endpoints are rejected before journal text is sent")
  func rejectsRemoteHTTP() async throws {
    var configuration = OpenAICompatibleProviderConfiguration.deepSeekDefault
    configuration.endpoint = try #require(URL(string: "http://example.com"))
    let transport = JournalRecordingTransport(data: Data())
    await #expect(throws: WorkReportProviderError.invalidEndpoint) {
      try await OpenAICompatibleJournalClient(transport: transport).generate(
        markdown: "不会发送",
        operation: .proofread,
        customInstruction: nil,
        configuration: configuration,
        credential: "test-key"
      )
    }
    #expect(await transport.request == nil)
  }
}

private actor JournalRecordingTransport: ProviderHTTPTransport {
  private let data: Data
  private(set) var request: URLRequest?

  init(data: Data) { self.data = data }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    self.request = request
    return (
      data,
      HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
      )!
    )
  }
}
