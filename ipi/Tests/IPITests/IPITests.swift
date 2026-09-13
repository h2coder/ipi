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
