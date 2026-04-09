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
