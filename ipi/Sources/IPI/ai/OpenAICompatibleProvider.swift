import Foundation

enum OpenAICompatibleProviderError: LocalizedError {
    case missingAPIKey(provider: String)
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for provider \(provider)."
        case .requestFailed(let statusCode, let body):
            return "Request failed with status \(statusCode): \(body)"
        }
    }
}

enum OpenAICompatibleProvider {
    static func stream(
        model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions
    ) -> IPIAssistantMessageEventStream {
        let stream = IPIAssistantMessageEventStream { event in
            switch event {
            case .done(_, let message):
                return message
            case .error(_, let error):
                return error
            default:
                return nil
            }
        }

        Task {
            let timestamp = Date()
            var content: [IPIAssistantContentBlock] = []
            var usage = IPIUsage.zero
            var stopReason: IPIStopReason = .stop
            var currentBlock: CurrentStreamBlock?

            func partialMessage(errorMessage: String? = nil) -> IPIAssistantMessage {
                IPIAssistantMessage(
                    content: content,
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: usage,
                    stopReason: stopReason,
                    errorMessage: errorMessage,
                    timestamp: timestamp
                )
            }

            func finishCurrentBlock() {
                guard let activeBlock = currentBlock else {
                    return
                }

                switch activeBlock {
                case .text(let index):
                    guard case .text(let text) = content[index] else {
                        break
                    }
                    stream.push(.textEnd(contentIndex: index, content: text, partial: partialMessage()))
                case .thinking(let index):
                    guard case .thinking(let thinking) = content[index] else {
                        break
                    }
                    stream.push(.thinkingEnd(contentIndex: index, content: thinking, partial: partialMessage()))
                case .toolCall(let index, _):
                    guard case .toolCall(let toolCall) = content[index] else {
                        break
                    }
                    stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: partialMessage()))
                }

                currentBlock = nil
            }

            func appendTextDelta(_ delta: String) {
                let index: Int

                if case .text(let currentIndex) = currentBlock {
                    index = currentIndex
                } else {
                    finishCurrentBlock()
                    content.append(.text(""))
                    index = content.count - 1
                    currentBlock = .text(index)
                    stream.push(.textStart(contentIndex: index, partial: partialMessage()))
                }

                let updatedText: String
                if case .text(let currentText) = content[index] {
                    updatedText = currentText + delta
                } else {
                    updatedText = delta
                }

                content[index] = .text(updatedText)
                stream.push(.textDelta(contentIndex: index, delta: delta, partial: partialMessage()))
            }

            func appendThinkingDelta(_ delta: String) {
                let index: Int

                if case .thinking(let currentIndex) = currentBlock {
                    index = currentIndex
                } else {
                    finishCurrentBlock()
                    content.append(.thinking(""))
                    index = content.count - 1
                    currentBlock = .thinking(index)
                    stream.push(.thinkingStart(contentIndex: index, partial: partialMessage()))
                }

                let updatedThinking: String
                if case .thinking(let currentThinking) = content[index] {
                    updatedThinking = currentThinking + delta
                } else {
                    updatedThinking = delta
                }

                content[index] = .thinking(updatedThinking)
                stream.push(.thinkingDelta(contentIndex: index, delta: delta, partial: partialMessage()))
            }

            func appendToolCallDelta(_ delta: ChatCompletionChunk.ToolCallDelta) {
                let index: Int
                var partialArguments = ""

                if case .toolCall(let currentIndex, let currentArguments) = currentBlock {
                    index = currentIndex
                    partialArguments = currentArguments
                } else {
                    finishCurrentBlock()
                    content.append(
                        .toolCall(
                            IPIToolCall(
                                id: delta.id ?? "",
                                name: delta.function?.name ?? "",
                                arguments: [:]
                            )
                        )
                    )
                    index = content.count - 1
                    currentBlock = .toolCall(index, "")
                    stream.push(.toolCallStart(contentIndex: index, partial: partialMessage()))
                }

                guard case .toolCall(let existingToolCall) = content[index] else {
                    return
                }

                let argumentsDelta = delta.function?.arguments ?? ""
                partialArguments += argumentsDelta

                let updatedToolCall = IPIToolCall(
                    id: delta.id ?? existingToolCall.id,
                    name: delta.function?.name ?? existingToolCall.name,
                    arguments: self.decodePartialArguments(
                        partialArguments,
                        fallback: existingToolCall.arguments
                    )
                )

                content[index] = .toolCall(updatedToolCall)
                currentBlock = .toolCall(index, partialArguments)
                stream.push(.toolCallDelta(contentIndex: index, delta: argumentsDelta, partial: partialMessage()))
            }

            do {
                let request = try self.makeRequest(
                    model: model,
                    context: context,
                    options: options,
                    stream: true
                )
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                try self.validate(response: response)

                stream.push(.start(partial: partialMessage()))

                for try await rawLine in bytes.lines {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard line.hasPrefix("data:") else {
                        continue
                    }

                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !payload.isEmpty else {
                        continue
                    }

                    if payload == "[DONE]" {
                        break
                    }

                    let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(payload.utf8))
                    if let chunkUsage = chunk.usage,
                       (chunkUsage.promptTokens ?? 0) > 0 || (chunkUsage.completionTokens ?? 0) > 0 || (chunkUsage.totalTokens ?? 0) > 0 {
                        usage = IPIUsage(
                            input: chunkUsage.promptTokens ?? 0,
                            output: chunkUsage.completionTokens ?? 0,
                            cacheRead: 0,
                            cacheWrite: 0,
                            totalTokens: chunkUsage.totalTokens ?? 0
                        )
                    }

                    guard let choice = chunk.choices.first else {
                        continue
                    }

                    if let finishReason = choice.finishReason {
                        stopReason = self.stopReason(from: finishReason)
                    }

                    if let reasoningDelta = choice.delta.reasoningContent,
                       !reasoningDelta.isEmpty {
                        appendThinkingDelta(reasoningDelta)
                    }

                    if let textDelta = choice.delta.content,
                       !textDelta.isEmpty {
                        appendTextDelta(textDelta)
                    }

                    for toolCallDelta in choice.delta.toolCalls ?? [] {
                        appendToolCallDelta(toolCallDelta)
                    }
                }

                finishCurrentBlock()
                stream.push(.done(reason: stopReason, message: partialMessage()))
            } catch {
                let errorMessage = IPIAssistantMessage(
                    content: content,
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: usage,
                    stopReason: .error,
                    errorMessage: error.localizedDescription
                )
                stream.push(.error(reason: .error, error: errorMessage))
            }
        }

        return stream
    }

    static func complete(
        model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions
    ) async throws -> IPIAssistantMessage {
        let request = try self.makeRequest(
            model: model,
            context: context,
            options: options,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try self.validate(response: response, body: data)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return try self.makeAssistantMessage(
            from: decoded,
            model: model
        )
    }

    private static func makeRequest(
        model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions,
        stream: Bool
    ) throws -> URLRequest {
        let apiKey = options.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw OpenAICompatibleProviderError.missingAPIKey(provider: model.provider)
        }

        let body = try self.requestBody(
            model: model,
            context: context,
            options: options,
            stream: stream
        )

        var request = URLRequest(url: model.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        for (key, value) in model.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        for (key, value) in options.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    private static func requestBody(
        model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions,
        stream: Bool
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": model.id,
            "stream": stream,
            "messages": self.requestMessages(from: context, model: model),
        ]

        if let temperature = options.temperature {
            payload["temperature"] = temperature
        }

        payload["max_tokens"] = options.maxTokens ?? model.maxTokens

        if model.reasoning {
            let shouldEnableThinking = options.reasoning != nil && options.reasoning != .off
            payload["enable_thinking"] = shouldEnableThinking
        }

        if !context.tools.isEmpty {
            payload["tools"] = context.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.mapValues(\.foundationValue),
                    ],
                ] as [String: Any]
            }
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func validate(response: URLResponse, body: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "IPI.OpenAICompatibleProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."]
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let bodyText = body.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty>"
            throw OpenAICompatibleProviderError.requestFailed(
                statusCode: httpResponse.statusCode,
                body: bodyText
            )
        }
    }

    private static func requestMessages(
        from context: IPIContext,
        model: IPIModel
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        if let systemPrompt = context.systemPrompt,
           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append([
                "role": "system",
                "content": systemPrompt,
            ])
        }

        for message in context.messages {
            switch message {
            case .user(let userMessage):
                if let content = self.userContent(for: userMessage, model: model) {
                    messages.append([
                        "role": "user",
                        "content": content,
                    ])
                }
            case .assistant(let assistantMessage):
                let textParts = assistantMessage.content.compactMap { block -> String? in
                    switch block {
                    case .text(let text):
                        return text
                    case .thinking(let thinking):
                        return thinking
                    case .toolCall:
                        return nil
                    }
                }

                let toolCalls = assistantMessage.toolCalls
                if textParts.isEmpty && toolCalls.isEmpty {
                    continue
                }

                var messageObject: [String: Any] = [
                    "role": "assistant",
                    "content": textParts.joined(separator: "\n\n"),
                ]

                if !toolCalls.isEmpty {
                    messageObject["tool_calls"] = toolCalls.map { toolCall in
                        [
                            "id": toolCall.id,
                            "type": "function",
                            "function": [
                                "name": toolCall.name,
                                "arguments": self.encodedJSONObject(toolCall.arguments),
                            ],
                        ] as [String: Any]
                    }
                }

                messages.append(messageObject)
            case .toolResult(let toolResultMessage):
                messages.append([
                    "role": "tool",
                    "tool_call_id": toolResultMessage.toolCallId,
                    "content": toolResultMessage.plainText,
                ])
            }
        }

        return messages
    }

    private static func userContent(
        for userMessage: IPIUserMessage,
        model: IPIModel
    ) -> Any? {
        if userMessage.content.count == 1,
           case .text(let text) = userMessage.content[0] {
            return text
        }

        let supportsImages = model.input.contains(.image)
        let parts: [[String: Any]] = userMessage.content.compactMap { block in
            switch block {
            case .text(let text):
                return [
                    "type": "text",
                    "text": text,
                ]
            case .image(let image):
                guard supportsImages else {
                    return nil
                }

                return [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(image.mimeType);base64,\(image.data)",
                    ],
                ]
            }
        }

        return parts.isEmpty ? nil : parts
    }

    private static func makeAssistantMessage(
        from response: ChatCompletionResponse,
        model: IPIModel
    ) throws -> IPIAssistantMessage {
        let choice = response.choices.first ?? ChatCompletionResponse.Choice(
            message: .init(content: nil, toolCalls: nil),
            finishReason: nil
        )

        var content: [IPIAssistantContentBlock] = []

        let text = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            content.append(.text(text))
        }

        for toolCall in choice.message.toolCalls ?? [] {
            let arguments = try self.argumentsObject(from: toolCall.function.arguments)
            content.append(
                .toolCall(
                    IPIToolCall(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        arguments: arguments
                    )
                )
            )
        }

        let usage = IPIUsage(
            input: response.usage?.promptTokens ?? 0,
            output: response.usage?.completionTokens ?? 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: response.usage?.totalTokens ?? 0
        )

        return IPIAssistantMessage(
            content: content,
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: usage,
            stopReason: self.stopReason(from: choice.finishReason),
            timestamp: .now
        )
    }

    private static func encodedJSONObject(_ object: JSONObject) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object.mapValues(\.foundationValue),
            options: [.sortedKeys]
        ),
        let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private static func argumentsObject(from jsonString: String) throws -> JSONObject {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [:]
        }

        return try JSONValue.decodeObject(from: trimmed)
    }

    private static func decodePartialArguments(
        _ jsonString: String,
        fallback: JSONObject
    ) -> JSONObject {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }

        return (try? JSONValue.decodeObject(from: trimmed)) ?? fallback
    }

    private static func stopReason(from finishReason: String?) -> IPIStopReason {
        switch finishReason {
        case "length":
            return .length
        case "tool_calls", "function_call":
            return .toolUse
        case "content_filter":
            return .error
        case "stop", nil:
            return .stop
        default:
            return .stop
        }
    }
}

private enum CurrentStreamBlock {
    case text(Int)
    case thinking(Int)
    case toolCall(Int, String)
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        let message: ResponseMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ResponseMessage: Decodable {
        let content: ResponseContent?
        let toolCalls: [ResponseToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ResponseToolCall: Decodable {
        struct FunctionPayload: Decodable {
            let name: String
            let arguments: String
        }

        let id: String
        let function: FunctionPayload
    }

    struct UsagePayload: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let choices: [Choice]
    let usage: UsagePayload?
}

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let role: String?
        let content: String?
        let toolCalls: [ToolCallDelta]?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
            case reasoningContent = "reasoning_content"
        }
    }

    struct ToolCallDelta: Decodable {
        struct FunctionPayload: Decodable {
            let name: String?
            let arguments: String?
        }

        let index: Int?
        let id: String?
        let function: FunctionPayload?
    }

    let choices: [Choice]
    let usage: ChatCompletionResponse.UsagePayload?
}

private enum ResponseContent: Decodable {
    case string(String)
    case array([ResponseContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        if let array = try? container.decode([ResponseContentPart].self) {
            self = .array(array)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported response content."
        )
    }

    var text: String {
        switch self {
        case .string(let string):
            return string
        case .array(let array):
            return array.compactMap(\.text).joined()
        }
    }
}

private struct ResponseContentPart: Decodable {
    let type: String?
    let text: String?
}
