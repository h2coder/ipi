import Foundation
import Testing
@testable import IPI

@Test("Model preserves provider configuration")
func modelPreservesProviderConfiguration() {
    let model = IPIModel(
        id: "Qwen/Qwen3.5-35B-A3B",
        provider: "modelscope",
        baseURL: URL(string: "https://api-inference.modelscope.cn/v1")!,
        reasoning: true
    )

    #expect(model.id == "Qwen/Qwen3.5-35B-A3B")
    #expect(model.provider == "modelscope")
    #expect(model.api == IPIAPI.openAICompletions)
}

@Test("JSON tool arguments decode into an object")
func jsonToolArgumentsDecodeIntoAnObject() throws {
    let object = try JSONValue.decodeObject(from: "{\"city\":\"Beijing\",\"count\":1}")

    #expect(object["city"] == .string("Beijing"))
    #expect(object["count"] == .number(1))
}

@Test("DeepSeek tool turns preserve reasoning content")
func deepSeekToolTurnsPreserveReasoningContent() {
    let model = IPIModel(
        id: "deepseek-flash",
        provider: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com")!,
        reasoning: true
    )
    let assistant = IPIAssistantMessage(
        content: [
            .thinking("I need to search the wardrobe first."),
            .toolCall(IPIToolCall(id: "call_1", name: "search_item", arguments: [:])),
        ],
        api: IPIAPI.openAICompletions,
        provider: "DeepSeek",
        model: "deepseek-flash",
        stopReason: .toolUse
    )
    let context = IPIContext(messages: [.assistant(assistant)])

    let messages = OpenAICompatibleProvider.requestMessages(from: context, model: model)

    #expect(messages.count == 1)
    #expect(messages[0]["reasoning_content"] as? String == "I need to search the wardrobe first.")
    #expect(messages[0]["content"] as? String == "")
    let toolCalls = messages[0]["tool_calls"] as? [[String: Any]]
    #expect(toolCalls?.first?["id"] as? String == "call_1")
}

/// Feed real SSE chunks through the provider without calling an external API.
private final class ToolStreamFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let calls: [[String: Any]] = [
            ["index": 0, "id": "wardrobe", "function": ["name": "search_item", "arguments": "{\"keyword\":"]],
            ["index": 1, "id": "web", "function": ["name": "search_web", "arguments": "{\"query\":"]],
            ["index": 0, "function": ["arguments": "\"skirt\"}"]],
            ["index": 1, "function": ["arguments": "\"white blouse\"}"]],
        ]
        let body = calls.map { call in
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [call]]]]])
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }.joined() + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test("Interleaved streamed tool calls keep separate names and arguments")
func interleavedToolCalls() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ToolStreamFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let model = IPIModel(id: "fixture", provider: "fixture", baseURL: URL(string: "https://fixture.test/v1")!)
    let stream = OpenAICompatibleProvider.stream(model: model, context: IPIContext(messages: []),
        options: IPIStreamOptions(apiKey: "fixture"), session: session)
    var endedCalls: [IPIToolCall] = []
    for await event in stream {
        if case .toolCallEnd(_, let call, _) = event { endedCalls.append(call) }
    }
    let result = await stream.result()
    #expect(result.stopReason == .toolUse)
    #expect(result.toolCalls.count == 2)
    #expect(result.toolCalls.first?.id == "wardrobe")
    #expect(result.toolCalls.first?.name == "search_item")
    #expect(result.toolCalls.first?.arguments == ["keyword": .string("skirt")])
    #expect(result.toolCalls.last?.id == "web")
    #expect(result.toolCalls.last?.name == "search_web")
    #expect(result.toolCalls.last?.arguments == ["query": .string("white blouse")])
    #expect(endedCalls == result.toolCalls)
}

@Test("DeepSeek uses its documented thinking toggle", arguments: [IPIThinkingLevel.off, .low, .high])
func deepSeekThinkingToggle(level: IPIThinkingLevel) throws {
    let model = IPIModel(id: "deepseek-flash", provider: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!, reasoning: true)
    let data = try OpenAICompatibleProvider.requestBody(model: model, context: IPIContext(messages: []),
        options: IPIStreamOptions(reasoning: level), stream: true)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((body["thinking"] as? [String: String])?["type"] == (level == .off ? "disabled" : "enabled"))
    #expect(body["enable_thinking"] == nil)
}

@Test("Other compatible providers keep enable_thinking")
func otherProviderThinkingToggle() throws {
    let model = IPIModel(id: "qwen", provider: "modelscope",
        baseURL: URL(string: "https://fixture.test/v1")!, reasoning: true)
    let data = try OpenAICompatibleProvider.requestBody(model: model, context: IPIContext(messages: []),
        options: IPIStreamOptions(reasoning: .off), stream: true)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["enable_thinking"] as? Bool == false)
    #expect(body["thinking"] == nil)
}

@Test("Responses API explicitly disables thinking")
func responsesThinkingOff() throws {
    let model = IPIModel(id: "deepseek-flash", provider: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!, reasoning: true)
    let request = try DeepSeekResponsesProvider.makeRequest(model: model, context: IPIContext(messages: []),
        options: IPIStreamOptions(apiKey: "fixture", reasoning: .off))
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((body["reasoning"] as? [String: String])?["effort"] == "none")
}

private final class AgentFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(IPIContext, IPIStreamOptions)] = []
    let repeatsTools: Bool
    init(repeatsTools: Bool = false) { self.repeatsTools = repeatsTools }
    var requests: [(IPIContext, IPIStreamOptions)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func response(model: IPIModel, context: IPIContext, options: IPIStreamOptions) -> IPIAssistantMessageEventStream {
        lock.lock(); recorded.append((context, options)); lock.unlock()
        let content: [IPIAssistantContentBlock] = !options.allowToolCalls || context.tools.isEmpty
            || (!repeatsTools && context.messages.contains(where: { if case .toolResult = $0 { true } else { false } }))
            ? [.text("complete")]
            : (0..<3).map { .toolCall(IPIToolCall(id: "call_\($0)", name: "read", arguments: [:])) }
        let message = IPIAssistantMessage(content: content, api: model.api, provider: model.provider,
            model: model.id, stopReason: content.count == 1 ? .stop : .toolUse)
        let stream = IPIAssistantMessageEventStream {
            if case .done(_, let message) = $0 { return message }; return nil
        }
        stream.push(.done(reason: message.stopReason, message: message))
        return stream
    }
}

private actor ConcurrentReadProbe {
    var active = 0
    var peak = 0
    var count = 0
    func read(_ id: String) async throws -> IPIAgentToolResult {
        active += 1
        peak = max(peak, active)
        count += 1
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(id == "call_0" ? 60 : 20))
        return IPIAgentToolResult(content: [.text(id)])
    }
}

@MainActor
@Test("Read tools overlap within the configured cap and preserve transcript order")
func parallelReads() async {
    let fixture = AgentFixture()
    let probe = ConcurrentReadProbe()
    let tool = IPIAgentTool(name: "read", label: "Read", description: "Read") { id, _, _ in
        try await probe.read(id)
    }
    let model = IPIModel(id: "fixture", provider: "fixture", baseURL: URL(string: "https://fixture.test")!)
    let agent = IPIAgent(model: model, tools: [tool], executionOptions: .init(maxConcurrentTools: 2))
    agent.streamResponse = { fixture.response(model: $0, context: $1, options: $2) }
    await agent.prompt("read")
    #expect(await probe.peak == 2)
    let results = agent.state.messages.compactMap { message -> String? in
        if case .toolResult(let result) = message { return result.toolCallId }; return nil
    }
    #expect(results == ["call_0", "call_1", "call_2"])
    #expect(fixture.requests.last?.1.reasoning == .off)
    #expect(agent.state.pendingToolCalls.isEmpty)
}

@MainActor
@Test("Tool budgets leave a final synthesis turn", arguments: [true, false])
func toolBudgets(limitByRounds: Bool) async {
    let fixture = AgentFixture(repeatsTools: true)
    let probe = ConcurrentReadProbe()
    let tool = IPIAgentTool(name: "read", label: "Read", description: "Read") { id, _, _ in
        try await probe.read(id)
    }
    let model = IPIModel(id: "fixture", provider: "fixture", baseURL: URL(string: "https://fixture.test")!)
    let agent = IPIAgent(model: model, tools: [tool], executionOptions: .init(
        maxToolRounds: limitByRounds ? 1 : 10, maxToolCalls: limitByRounds ? 20 : 1, maxConcurrentTools: 2))
    agent.streamResponse = { fixture.response(model: $0, context: $1, options: $2) }
    await agent.prompt("read")
    #expect(await probe.count == (limitByRounds ? 3 : 1))
    #expect(fixture.requests.count == 2)
    #expect(fixture.requests.last?.0.tools.isEmpty == false)
    #expect(fixture.requests.last?.1.allowToolCalls == false)
    #expect(fixture.requests.last?.0.systemPrompt?.contains("Tool budget reached") == true)
    if case .assistant(let final) = agent.state.messages.last {
        #expect(final.plainText == "complete")
    } else { Issue.record("Missing final synthesis") }
}

@Test("Cancelling a stream consumer cancels its producer")
func streamCancellation() async {
    let stream = IPIAssistantMessageEventStream {
        if case .error(_, let message) = $0 { return message }; return nil
    }
    let producer = Task {
        do { try await Task.sleep(for: .seconds(30)) } catch {
            let message = IPIAssistantMessage(content: [], api: IPIAPI.openAICompletions,
                provider: "fixture", model: "fixture", stopReason: .aborted)
            stream.push(.error(reason: .aborted, error: message))
        }
    }
    stream.attachProducer(producer)
    let consumer = Task { for await _ in stream {} }
    consumer.cancel()
    await consumer.value
    let result = await stream.result()
    #expect(result.stopReason == .aborted)
}

@MainActor
@Test("Slow tools time out and the agent can still answer")
func slowToolBudget() async {
    let fixture = AgentFixture()
    let tool = IPIAgentTool(name: "read", label: "Read", description: "Read") { _, _, _ in
        try await Task.sleep(for: .seconds(30))
        return IPIAgentToolResult(content: [.text("too late")])
    }
    let model = IPIModel(id: "fixture", provider: "fixture", baseURL: URL(string: "https://fixture.test")!)
    let agent = IPIAgent(model: model, tools: [tool], executionOptions: .init(
        maxConcurrentTools: 3, maxToolDuration: .milliseconds(20)))
    agent.streamResponse = { fixture.response(model: $0, context: $1, options: $2) }
    await agent.prompt("read")
    let results = agent.state.messages.compactMap { message -> IPIToolResultMessage? in
        if case .toolResult(let result) = message { return result }; return nil
    }
    #expect(results.count == 3)
    #expect(results.allSatisfy { $0.isError && $0.plainText.contains("time budget exceeded") })
    if case .assistant(let final) = agent.state.messages.last {
        #expect(final.plainText == "complete")
    } else { Issue.record("Missing answer after tool timeout") }
}


@Test("Final synthesis disables tool calls while retaining their definitions")
func finalSynthesisToolChoice() throws {
    let model = IPIModel(id: "deepseek-flash", provider: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!, reasoning: true)
    let context = IPIContext(messages: [], tools: [IPIToolDefinition(name: "read", description: "Read", parameters: [:])])
    let options = IPIStreamOptions(apiKey: "fixture", reasoning: .off, allowToolCalls: false)
    let data = try OpenAICompatibleProvider.requestBody(model: model, context: context, options: options, stream: true)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["tool_choice"] as? String == "none")
    #expect((body["tools"] as? [[String: Any]])?.count == 1)
    let request = try DeepSeekResponsesProvider.makeRequest(model: model, context: context, options: options)
    let responseData = try #require(request.httpBody)
    let responseBody = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    #expect(responseBody["tool_choice"] as? String == "none")
    #expect((responseBody["tools"] as? [[String: Any]])?.count == 1)
}
