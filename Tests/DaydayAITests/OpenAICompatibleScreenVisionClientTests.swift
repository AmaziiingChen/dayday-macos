import DaydayAI
import DaydayCore
import Foundation
import Testing

struct OpenAICompatibleScreenVisionClientTests {
  @Test
  func sendsBoundedImageAndDecodesStrictInference() async throws {
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"正在编辑代码\",\"interaction\":\"编辑器中显示 Swift 源码并有插入光标\",\"activity_kind\":\"development\",\"confidence\":0.87,\"evidence\":[\"源码编辑区可见\",\"插入光标可见\"],\"display_states\":[{\"display_label\":\"display-test\",\"role\":\"primary\",\"visible_state\":\"Swift 编辑器\"}],\"relationship\":\"coordinated\",\"uncertainties\":[]}",
        id: "vision-request-1",
        usage: "\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":32,\"total_tokens\":152}"
      )
    )
    let image = try EphemeralVisionImage(
      data: Data([0xFF, 0xD8, 0xFF]),
      mediaType: .jpeg,
      pixelWidth: 1_280,
      pixelHeight: 720
    )
    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: try Self.batch(
        image: image,
        ocr: [try RedactedOCRLine("func generateReport()")],
        systemContext: .init(foregroundApplicationLabel: "Xcode", focusedWindowTitle: "Report")
      ),
      configuration: .init(
        endpoint: URL(string: "https://vision.example.com/v1")!,
        model: "example-vision"
      ),
      credential: "test-credential"
    )

    #expect(response.requestID == "vision-request-1")
    #expect(response.inference.activityKind == .development)
    #expect(response.inference.displayStates.first?.role == .primary)
    #expect(response.usage?.totalTokens == 152)

    let request = try #require(await transport.lastRequest)
    #expect(request.url?.absoluteString == "https://vision.example.com/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-credential")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "example-vision")
    #expect(json["enable_thinking"] as? Bool == false)
    #expect(json["max_tokens"] as? Int == 2_400)
    #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    let imageURL = try #require(content.last?["image_url"] as? [String: String])
    #expect(imageURL["url"] == "data:image/jpeg;base64,/9j/")
    #expect(String(decoding: body, as: UTF8.self).contains("func generateReport()"))
    #expect(String(decoding: body, as: UTF8.self).contains("系统上下文：当前"))
    #expect(String(decoding: body, as: UTF8.self).contains("应用标签：Xcode"))
    #expect(String(decoding: body, as: UTF8.self).contains("工作意图"))
  }

  @Test
  func decodesOneWindowIntoOrderedEvidenceBoundSegments() async throws {
    let content = """
      {"segments":[
        {"start_time_slice":1,"end_time_slice":1,"summary":"查阅资料","interaction":"参考页面可见","activity_kind":"reading","confidence":0.8,"evidence":["资料页可见"],"display_states":[{"display_label":"display-test","role":"reference","visible_state":"资料页面"}],"relationship":"coordinated","system_context_agreement":"unavailable","uncertainties":[]},
        {"start_time_slice":2,"end_time_slice":2,"summary":"编辑代码","interaction":"编辑器内容发生变化","activity_kind":"development","confidence":0.9,"evidence":["源码可见"],"display_states":[{"display_label":"display-test","role":"primary","visible_state":"代码编辑器"}],"relationship":"coordinated","system_context_agreement":"unavailable","uncertainties":[]}
      ]}
      """
    let transport = VisionRecordingTransport(status: 200, body: Self.responseContent(content))
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let batch = try ScreenVisualTimelineBatch(timeSlices: [
      try .init(frames: [
        try .init(image: image, observedAt: start, displayLabel: "display-test", redactedOCRLines: [])
      ]),
      try .init(frames: [
        try .init(
          image: image, observedAt: start.addingTimeInterval(60),
          displayLabel: "display-test", redactedOCRLines: [])
      ]),
    ])

    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: batch,
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    #expect(response.segments.count == 2)
    #expect(response.segments.map(\.timeSliceRange) == [0...0, 1...1])
    #expect(response.segments.map(\.inference.activityKind) == [.reading, .development])
  }

  @Test
  func repairsNarrowSingleSegmentCoverageAndExtraSingleDisplayState() async throws {
    let content = """
      {"segments":[{"start_time_slice":1,"end_time_slice":1,"summary":"连续处理报告","interaction":"文档内容持续可见","activity_kind":"writing","evidence":["报告页面可见"],"display_states":[{"display_label":"display-test","role":"primary","visible_state":"报告编辑器"},{"display_label":"provider-extra","role":"reference","visible_state":"虚构的额外屏幕"}],"relationship":"coordinated","system_context_agreement":"unavailable","uncertainties":[]}]}
      """
    let transport = VisionRecordingTransport(status: 200, body: Self.responseContent(content))
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let batch = try ScreenVisualTimelineBatch(timeSlices: [
      try .init(frames: [
        try .init(image: image, observedAt: start, displayLabel: "display-test", redactedOCRLines: [])
      ]),
      try .init(frames: [
        try .init(
          image: image, observedAt: start.addingTimeInterval(60), displayLabel: "display-test",
          redactedOCRLines: [])
      ]),
    ])

    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: batch,
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    #expect(response.segments.map(\.timeSliceRange) == [0...1])
    #expect(response.inference.displayStates.map(\.displayLabel) == ["display-test"])
    #expect(response.inference.relationship == .uncertain)
    #expect(response.inference.uncertainties.contains { $0.contains("多余屏幕状态") })
  }

  @Test
  func normalizesVerboseProviderProseWithoutWeakeningTheClosedSchema() async throws {
    let summary = String(repeating: "可见工作情境", count: 120) + "\n继续"
    let interaction = String(repeating: "跨帧状态变化", count: 120)
    let visibleState = String(repeating: "编辑器与聊天窗口可见", count: 100)
    let evidence = (0..<10).map { index in
      String(repeating: "依据\(index)", count: 100)
    }
    let payload: [String: Any] = [
      "summary": summary,
      "interaction": interaction,
      "activity_kind": "development",
      "confidence": 0.75,
      "evidence": evidence,
      "display_states": [
        [
          "display_label": "display-test",
          "role": "primary",
          "visible_state": visibleState,
        ]
      ],
      "relationship": "coordinated",
      "system_context_agreement": "unavailable",
      "uncertainties": (0..<6).map { "不确定项 \($0)\n仍需核对" },
    ]
    let content = String(
      decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      as: UTF8.self
    )
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(content)
    )
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)

    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: try Self.batch(image: image),
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    #expect(response.inference.summary.utf8.count <= 1_024)
    #expect(!response.inference.summary.contains("\n"))
    #expect(response.inference.interaction.utf8.count <= 1_024)
    #expect(response.inference.evidence.count == 8)
    #expect(response.inference.evidence.allSatisfy { $0.utf8.count <= 256 })
    #expect(response.inference.displayStates.count == 1)
    #expect(response.inference.displayStates[0].visibleState.utf8.count <= 600)
    #expect(response.inference.uncertainties.count == 4)
    #expect(response.inference.uncertainties.allSatisfy { !$0.contains("\n") })
  }

  @Test
  func sendsChronologicalMultiDisplayFramesInOneRequest() async throws {
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"跨屏查阅并编写日报\",\"interaction\":\"两块显示器上的内容按时间变化\",\"activity_kind\":\"writing\",\"confidence\":0.8,\"evidence\":[\"三帧可见\"],\"display_states\":[{\"display_label\":\"display-a\",\"role\":\"primary\",\"visible_state\":\"报告编辑\"},{\"display_label\":\"display-b\",\"role\":\"reference\",\"visible_state\":\"资料查阅\"}],\"relationship\":\"coordinated\",\"uncertainties\":[] }"
      )
    )
    let image = try EphemeralVisionImage(
      data: Data([0xFF, 0xD8, 0xFF]), mediaType: .jpeg, pixelWidth: 1_600, pixelHeight: 900)
    let start = Date(timeIntervalSinceReferenceDate: 2_000)
    let batch = try ScreenVisualTimelineBatch(
      timeSlices: [
        try .init(
          frames: [
            try .init(
              image: image, observedAt: start, displayLabel: "display-a", redactedOCRLines: []),
            try .init(
              image: image, observedAt: start, displayLabel: "display-b", redactedOCRLines: []),
          ],
          systemContext: .init(foregroundApplicationLabel: "WeChat")
        ),
        try .init(
          frames: [
            try .init(
              image: image, observedAt: start.addingTimeInterval(20), displayLabel: "display-a",
              redactedOCRLines: [])
          ],
          systemContext: .init(foregroundApplicationLabel: "Xcode")
        ),
      ],
      continuityContext: try .init(recentSegments: [
        try .init(
          summary: "在 WeChat 对话窗口中起草回复",
          activityKind: .writing,
          foregroundApplicationLabel: "WeChat"
        )
      ])
    )

    _ = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: batch,
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    let request = try #require(await transport.lastRequest)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.filter { $0["type"] as? String == "image_url" }.count == 3)
    let prompt = try #require(content.first?["text"] as? String)
    #expect(prompt.contains("时间片 1"))
    #expect(prompt.contains("display-a"))
    #expect(prompt.contains("display-b"))
    #expect(prompt.contains("应用标签：WeChat"))
    #expect(prompt.contains("应用标签：Xcode"))
    #expect(prompt.contains("下方“既往片段”只是本地模型的暂定连续性提示"))
    #expect(prompt.contains("在 WeChat 对话窗口中起草回复"))
    #expect(prompt.contains("不得翻译、改名、新增或遗漏"))
  }

  @Test
  func reconcilesParaphrasedAndCombinedDisplayLabelsWithExplicitUncertainty() async throws {
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"跨屏查阅并编写日报\",\"interaction\":\"两块显示器内容可见\",\"activity_kind\":\"writing\",\"confidence\":0.8,\"evidence\":[\"双屏可见\"],\"display_states\":[{\"display_label\":\"左侧屏幕\",\"role\":\"primary\",\"visible_state\":\"报告编辑\"},{\"display_label\":\"右侧屏幕\",\"role\":\"reference\",\"visible_state\":\"资料查阅\"}],\"relationship\":\"coordinated\",\"uncertainties\":[]}"
      )
    )
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let observedAt = Date(timeIntervalSinceReferenceDate: 2_500)
    let batch = try ScreenVisualTimelineBatch(
      timeSlices: [
        try .init(frames: [
          try .init(
            image: image,
            observedAt: observedAt,
            displayLabel: "display-a",
            redactedOCRLines: []
          ),
          try .init(
            image: image,
            observedAt: observedAt,
            displayLabel: "display-b",
            redactedOCRLines: []
          ),
        ])
      ]
    )

    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: batch,
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    #expect(response.inference.displayStates.map(\.displayLabel) == ["display-a", "display-b"])
    #expect(response.inference.displayStates.map(\.visibleState) == ["报告编辑", "资料查阅"])

    let combined = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"跨屏工作\",\"interaction\":\"画面可见\",\"activity_kind\":\"writing\",\"confidence\":0.6,\"evidence\":[],\"display_states\":[{\"display_label\":\"合并画面\",\"role\":\"primary\",\"visible_state\":\"只返回一项\"}],\"relationship\":\"uncertain\",\"uncertainties\":[]}"
      )
    )
    let combinedResponse = try await OpenAICompatibleScreenVisionClient(transport: combined).infer(
      batch: batch,
      configuration: .init(
        endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )
    #expect(
      combinedResponse.inference.displayStates.map(\.displayLabel) == ["display-a", "display-b"])
    #expect(combinedResponse.inference.displayStates.allSatisfy { $0.role == .unknown })
    #expect(combinedResponse.inference.relationship == .uncertain)
    #expect(combinedResponse.inference.uncertainties.contains { $0.contains("未完整逐屏返回状态") })

    let fourDisplayLabels = ["display-a", "display-b", "display-c", "display-d"]
    let fourDisplayBatch = try ScreenVisualTimelineBatch(timeSlices: [
      try .init(
        frames: try fourDisplayLabels.map {
          try .init(
            image: image,
            observedAt: observedAt,
            displayLabel: $0,
            redactedOCRLines: []
          )
        })
    ])
    let partial = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"四屏工作\",\"interaction\":\"仅返回两项屏幕状态\",\"activity_kind\":\"writing\",\"confidence\":0.7,\"evidence\":[],\"display_states\":[{\"display_label\":\"左侧\",\"role\":\"primary\",\"visible_state\":\"编辑报告\"},{\"display_label\":\"右侧\",\"role\":\"reference\",\"visible_state\":\"查阅资料\"}],\"relationship\":\"coordinated\",\"uncertainties\":[]}"
      )
    )
    let partialResponse = try await OpenAICompatibleScreenVisionClient(transport: partial).infer(
      batch: fourDisplayBatch,
      configuration: .init(
        endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )
    #expect(partialResponse.inference.displayStates.count == 4)
    #expect(partialResponse.inference.displayStates.allSatisfy { $0.role == .unknown })
    #expect(
      partialResponse.inference.displayStates.allSatisfy {
        $0.visibleState == "编辑报告；查阅资料"
      })
    #expect(partialResponse.inference.relationship == .uncertain)

    let extra = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"跨屏工作\",\"interaction\":\"画面可见\",\"activity_kind\":\"writing\",\"confidence\":0.6,\"evidence\":[],\"display_states\":[{\"display_label\":\"一\",\"role\":\"primary\",\"visible_state\":\"状态一\"},{\"display_label\":\"二\",\"role\":\"reference\",\"visible_state\":\"状态二\"},{\"display_label\":\"三\",\"role\":\"unknown\",\"visible_state\":\"额外状态\"}],\"relationship\":\"uncertain\",\"uncertainties\":[]}"
      )
    )
    await #expect(throws: ScreenVisionProviderError.invalidResponse) {
      try await OpenAICompatibleScreenVisionClient(transport: extra).infer(
        batch: batch,
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
        credential: "key"
      )
    }
  }

  @Test
  func reconcilesOneProviderStatePerInputFrameAndKeepsEachDisplaysLatestState() async throws {
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"跨屏内容发生变化\",\"interaction\":\"第四个时间片显示更新后的内容\",\"activity_kind\":\"development\",\"confidence\":0.7,\"evidence\":[\"八帧可见\"],\"display_states\":[{\"display_label\":\"屏幕\",\"role\":\"primary\",\"visible_state\":\"第一段编辑器\"},{\"display_label\":\"屏幕\",\"role\":\"reference\",\"visible_state\":\"第一段资料\"},{\"display_label\":\"屏幕\",\"role\":\"primary\",\"visible_state\":\"第二段编辑器\"},{\"display_label\":\"屏幕\",\"role\":\"reference\",\"visible_state\":\"第二段资料\"},{\"display_label\":\"屏幕\",\"role\":\"primary\",\"visible_state\":\"第三段编辑器\"},{\"display_label\":\"屏幕\",\"role\":\"reference\",\"visible_state\":\"第三段资料\"},{\"display_label\":\"屏幕\",\"role\":\"primary\",\"visible_state\":\"最终编辑器\"},{\"display_label\":\"屏幕\",\"role\":\"communication\",\"visible_state\":\"最终聊天\"}],\"relationship\":\"coordinated\",\"uncertainties\":[]}"
      )
    )
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let observedAt = Date(timeIntervalSinceReferenceDate: 3_000)
    let frames: (Date) throws -> [ScreenVisualTimelineFrame] = { date in
      [
        try .init(
          image: image, observedAt: date, displayLabel: "display-a", redactedOCRLines: []),
        try .init(
          image: image, observedAt: date, displayLabel: "display-b", redactedOCRLines: []),
      ]
    }
    let batch = try ScreenVisualTimelineBatch(timeSlices: [
      try .init(frames: frames(observedAt)),
      try .init(frames: frames(observedAt.addingTimeInterval(20))),
      try .init(frames: frames(observedAt.addingTimeInterval(40))),
      try .init(frames: frames(observedAt.addingTimeInterval(60))),
    ])

    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: batch,
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )

    #expect(response.inference.displayStates.map(\.displayLabel) == ["display-a", "display-b"])
    #expect(response.inference.displayStates.map(\.visibleState) == ["最终编辑器", "最终聊天"])
    #expect(response.inference.displayStates.map(\.role) == [.primary, .communication])
  }

  @Test
  func rejectsOriginalResolutionAndOversizedImagesBeforeTransport() async throws {
    #expect(throws: EphemeralVisionImage.ValidationError.exceedsMaximumDimension(3_840)) {
      _ = try EphemeralVisionImage(
        data: Data([1]), mediaType: .jpeg, pixelWidth: 3_840, pixelHeight: 2_160)
    }
    #expect(
      throws: EphemeralVisionImage.ValidationError.exceedsMaximumBytes(
        EphemeralVisionImage.maximumBytes + 1)
    ) {
      _ = try EphemeralVisionImage(
        data: Data(repeating: 1, count: EphemeralVisionImage.maximumBytes + 1),
        mediaType: .jpeg,
        pixelWidth: 1_280,
        pixelHeight: 720
      )
    }
  }

  @Test
  func ignoresLegacyConfidenceAndAdditiveProviderFields() async throws {
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let configuration = OpenAICompatibleVisionConfiguration(
      endpoint: URL(string: "https://vision.example.com")!, model: "vision")

    let unknown = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"工作\",\"interaction\":\"阅读\",\"activity_kind\":\"reading\",\"confidence\":0.8,\"evidence\":[\"文档可见\"],\"display_states\":[{\"display_label\":\"display-test\",\"role\":\"primary\",\"visible_state\":\"文档\"}],\"relationship\":\"coordinated\",\"uncertainties\":[],\"score\":99}"
      )
    )
    _ = try await OpenAICompatibleScreenVisionClient(transport: unknown).infer(
      batch: try Self.batch(image: image), configuration: configuration, credential: "key")

    let invalidConfidence = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"工作\",\"interaction\":\"阅读\",\"activity_kind\":\"reading\",\"confidence\":1.2,\"evidence\":[\"文档可见\"],\"display_states\":[{\"display_label\":\"display-test\",\"role\":\"primary\",\"visible_state\":\"文档\"}],\"relationship\":\"coordinated\",\"uncertainties\":[]}"
      )
    )
    _ = try await OpenAICompatibleScreenVisionClient(transport: invalidConfidence).infer(
      batch: try Self.batch(image: image), configuration: configuration, credential: "key")
  }

  @Test
  func keepsTypedSystemContextConflictAndRequiresTheExactSchema() async throws {
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"聊天界面\",\"interaction\":\"输入区域可见\",\"activity_kind\":\"communication\",\"confidence\":0.4,\"evidence\":[\"聊天窗口可见\"],\"display_states\":[{\"display_label\":\"display-test\",\"role\":\"communication\",\"visible_state\":\"聊天窗口\"}],\"relationship\":\"coordinated\",\"system_context_agreement\":\"conflicts\",\"uncertainties\":[\"系统应用与画面身份不一致\"]}"
      )
    )
    let response = try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
      batch: try Self.batch(
        image: image,
        systemContext: .init(foregroundApplicationLabel: "WeChat", freshness: .current)
      ),
      configuration: .init(endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
      credential: "key"
    )
    #expect(response.inference.systemContextAgreement == .conflicts)
  }

  @Test
  func mapsHTTPFailuresWithoutExposingProviderBody() async throws {
    let image = try EphemeralVisionImage(
      data: Data([1]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
    let transport = VisionRecordingTransport(status: 429, body: "provider-secret-body")
    await #expect(throws: ScreenVisionProviderError.rateLimited) {
      try await OpenAICompatibleScreenVisionClient(transport: transport).infer(
        batch: try Self.batch(image: image),
        configuration: .init(
          endpoint: URL(string: "https://vision.example.com")!, model: "vision"),
        credential: "key"
      )
    }
  }

  @Test
  func connectionProbeUsesProviderCompatibleNeutralImage() async throws {
    let transport = VisionRecordingTransport(
      status: 200,
      body: Self.responseContent(
        "{\"summary\":\"空白图像\",\"interaction\":\"未观察到交互\",\"activity_kind\":\"uncertain\",\"confidence\":0.1,\"evidence\":[\"纯白画面\"],\"display_states\":[{\"display_label\":\"connection-test\",\"role\":\"unknown\",\"visible_state\":\"空白\"}],\"relationship\":\"uncertain\",\"uncertainties\":[\"无法识别工作内容\"]}"
      )
    )
    try await OpenAICompatibleScreenVisionClient(transport: transport).testConnection(
      configuration: .init(
        endpoint: URL(string: "https://vision.example.com/v1")!, model: "qwen3-vl-flash"),
      credential: "key"
    )

    let request = try #require(await transport.lastRequest)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    let image = try #require(content.last?["image_url"] as? [String: String])
    let encoded = try #require(image["url"]?.split(separator: ",", maxSplits: 1).last)
    let png = try #require(Data(base64Encoded: String(encoded)))
    #expect(png.count > 24)
    #expect(Array(png[16..<20]) == [0, 0, 0, 16])
    #expect(Array(png[20..<24]) == [0, 0, 0, 16])
  }

  private static func responseContent(
    _ content: String,
    id: String? = nil,
    usage: String? = nil
  ) -> String {
    let normalizedContent: String
    if var payload = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
      payload["segments"] == nil
    {
      payload["system_context_agreement"] = payload["system_context_agreement"] ?? "unavailable"
      normalizedContent = String(
        decoding: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
        as: UTF8.self
      )
    } else {
      normalizedContent = content
    }
    let escaped =
      normalizedContent
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
    let usageField = usage.map { ",\($0)" } ?? ""
    return "{\(idField)\"choices\":[{\"message\":{\"content\":\"\(escaped)\"}}]\(usageField)}"
  }

  private static func batch(
    image: EphemeralVisionImage,
    ocr: [RedactedOCRLine] = [],
    systemContext: ScreenVisualSystemContext = .init()
  ) throws -> ScreenVisualTimelineBatch {
    try ScreenVisualTimelineBatch(
      frames: [
        try ScreenVisualTimelineFrame(
          image: image,
          observedAt: Date(timeIntervalSinceReferenceDate: 1_000),
          displayLabel: "display-test",
          redactedOCRLines: ocr
        )
      ],
      systemContext: systemContext
    )
  }
}

private actor VisionRecordingTransport: ProviderHTTPTransport {
  private let status: Int
  private let body: String
  private(set) var lastRequest: URLRequest?

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}
