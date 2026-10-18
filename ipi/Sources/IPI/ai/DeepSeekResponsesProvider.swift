import Foundation

enum DeepSeekResponsesProvider {
    static func stream(model: IPIModel, context: IPIContext, options: IPIStreamOptions) -> IPIAssistantMessageEventStream {
        let stream = IPIAssistantMessageEventStream { event in
            switch event {
            case .done(_, let message), .error(_, let message): message
            default: nil
            }
        }

        Task {
            var content: [IPIAssistantContentBlock] = []
            var usage = IPIUsage.zero
            var stopReason: IPIStopReason = .stop
            var textIndex: Int?
            var reasoningIndex: Int?
            var completed = false

            func message(error: String? = nil) -> IPIAssistantMessage {
                IPIAssistantMessage(content: content, api: model.api, provider: model.provider,
                                    model: model.id, usage: usage, stopReason: error == nil ? stopReason : .error,
                                    errorMessage: error)
            }

            func addText(_ delta: String, reasoning: Bool) {
                guard !delta.isEmpty else { return }
                let index: Int
                if reasoning, let existing = reasoningIndex { index = existing }
                else if !reasoning, let existing = textIndex { index = existing }
                else {
                    index = content.count
                    content.append(reasoning ? .thinking("") : .text(""))
                    if reasoning {
                        reasoningIndex = index
                        stream.push(.thinkingStart(contentIndex: index, partial: message()))
                    } else {
                        textIndex = index
                        stream.push(.textStart(contentIndex: index, partial: message()))
                    }
                }
                if reasoning {
                    guard case .thinking(let old) = content[index] else { return }
                    content[index] = .thinking(old + delta)
                    stream.push(.thinkingDelta(contentIndex: index, delta: delta, partial: message()))
                } else {
                    guard case .text(let old) = content[index] else { return }
                    content[index] = .text(old + delta)
                    stream.push(.textDelta(contentIndex: index, delta: delta, partial: message()))
                }
            }

            func finishBlocks() {
                if let index = textIndex, case .text(let text) = content[index] {
                    stream.push(.textEnd(contentIndex: index, content: text, partial: message()))
                }
                if let index = reasoningIndex, case .thinking(let text) = content[index] {
                    stream.push(.thinkingEnd(contentIndex: index, content: text, partial: message()))
                }
            }

            func process(_ data: String) throws {
                guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                      let type = object["type"] as? String else { return }
                switch type {
                case "response.output_text.delta":
                    addText(object["delta"] as? String ?? "", reasoning: false)
                case "response.reasoning_text.delta":
                    addText(object["delta"] as? String ?? "", reasoning: true)
                case "response.output_item.done":
                    if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call",
                       let callID = item["call_id"] as? String,
                       let name = item["name"] as? String {
                        let arguments = (try? JSONValue.decodeObject(from: item["arguments"] as? String ?? "{}")) ?? [:]
                        let index = content.count
                        let call = IPIToolCall(id: callID, name: name, arguments: arguments)
                        content.append(.toolCall(call))
                        stream.push(.toolCallStart(contentIndex: index, partial: message()))
                        stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: message()))
                    }
                case "response.completed", "response.incomplete", "response.failed":
                    completed = true
                    let response = object["response"] as? [String: Any] ?? [:]
                    let usageObject = response["usage"] as? [String: Any] ?? [:]
                    let input = usageObject["input_tokens"] as? Int ?? 0
                    let output = usageObject["output_tokens"] as? Int ?? 0
                    let inputDetails = usageObject["input_tokens_details"] as? [String: Any] ?? [:]
                    usage = IPIUsage(input: input, output: output,
                                     cacheRead: inputDetails["cached_tokens"] as? Int ?? 0,
                                     totalTokens: usageObject["total_tokens"] as? Int ?? input + output)
                    if type == "response.failed" {
                        let error = response["error"] as? [String: Any] ?? [:]
                        throw NSError(domain: "DeepSeekResponsesProvider", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Response failed."])
                    }
                    if type == "response.incomplete" { stopReason = .length }
                    // Some servers send a completed response without preceding text deltas.
                    if textIndex == nil, let output = response["output"] as? [[String: Any]] {
                        for item in output where item["type"] as? String == "message" {
                            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                                addText(part["text"] as? String ?? "", reasoning: false)
                            }
                        }
                    }
                default: break
                }
            }

            do {
                let request = try makeRequest(model: model, context: context, options: options)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "DeepSeekResponsesProvider", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
                }
                guard (200..<300).contains(http.statusCode) else {
                    var body = ""
                    for try await line in bytes.lines { body += line }
                    throw OpenAICompatibleProviderError.requestFailed(statusCode: http.statusCode, body: body)
                }
                stream.push(.start(partial: message()))
                for try await line in bytes.lines {
                    if line.hasPrefix("data:") {
                        try process(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                }
                guard completed else {
                    throw NSError(domain: "DeepSeekResponsesProvider", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Response stream ended before completion."])
                }
                finishBlocks()
                stream.push(.done(reason: stopReason, message: message()))
            } catch {
                stream.push(.error(reason: .error, error: message(error: error.localizedDescription)))
            }
        }
        return stream
    }

    private static func makeRequest(model: IPIModel, context: IPIContext, options: IPIStreamOptions) throws -> URLRequest {
        let apiKey = options.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw OpenAICompatibleProviderError.missingAPIKey(provider: model.provider) }

        var input: [[String: Any]] = []
        for message in context.messages {
            switch message {
            case .user(let user):
                input.append(["role": "user", "content": user.plainText])
            case .assistant(let assistant):
                if !assistant.plainText.isEmpty {
                    input.append(["role": "assistant", "content": assistant.plainText])
                }
                for call in assistant.toolCalls {
                    let arguments = try JSONSerialization.data(withJSONObject: call.arguments.mapValues(\.foundationValue))
                    input.append(["type": "function_call", "call_id": call.id, "name": call.name,
                                  "arguments": String(decoding: arguments, as: UTF8.self)])
                }
            case .toolResult(let result):
                input.append(["type": "function_call_output", "call_id": result.toolCallId,
                              "output": result.plainText])
            }
        }

        var body: [String: Any] = ["model": model.id, "input": input, "stream": true,
                                   "max_output_tokens": options.maxTokens ?? model.maxTokens]
        if let prompt = context.systemPrompt, !prompt.isEmpty { body["instructions"] = prompt }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let reasoning = options.reasoning { body["reasoning"] = ["effort": reasoning == .off ? "none" : reasoning.rawValue] }
        let tools = context.tools.map { tool in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": tool.parameters.mapValues(\.foundationValue)] as [String: Any]
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        var request = URLRequest(url: model.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in model.headers { request.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in options.additionalHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}
