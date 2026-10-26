import Foundation

@MainActor
public final class IPIAgent {
    public private(set) var state: IPIAgentState

    private var streamOptions: IPIStreamOptions
    private let executionOptions: IPIAgentExecutionOptions
    // Internal seam for deterministic agent-loop tests.
    var streamResponse: @Sendable (IPIModel, IPIContext, IPIStreamOptions) -> IPIAssistantMessageEventStream = {
        IPIAI.streamSimple($0, context: $1, options: $2)
    }
    private var listeners: [UUID: (IPIAgentEvent) -> Void] = [:]

    public init(
        initialState: IPIAgentState,
        streamOptions: IPIStreamOptions = .init(),
        executionOptions: IPIAgentExecutionOptions = .init()
    ) {
        self.state = initialState
        self.streamOptions = streamOptions
        self.executionOptions = executionOptions
    }

    public convenience init(
        model: IPIModel,
        systemPrompt: String = "",
        thinkingLevel: IPIThinkingLevel = .off,
        tools: [IPIAgentTool] = [],
        messages: [IPIAgentMessage] = [],
        streamOptions: IPIStreamOptions = .init(),
        executionOptions: IPIAgentExecutionOptions = .init()
    ) {
        self.init(
            initialState: IPIAgentState(
                systemPrompt: systemPrompt,
                model: model,
                thinkingLevel: thinkingLevel,
                tools: tools,
                messages: messages
            ),
            streamOptions: streamOptions,
            executionOptions: executionOptions
        )
    }

    @discardableResult
    public func subscribe(_ listener: @escaping (IPIAgentEvent) -> Void) -> UUID {
        let token = UUID()
        self.listeners[token] = listener
        return token
    }

    public func unsubscribe(_ token: UUID) {
        self.listeners.removeValue(forKey: token)
    }

    public func setSystemPrompt(_ systemPrompt: String) {
        self.state.systemPrompt = systemPrompt
    }

    public func setModel(_ model: IPIModel) {
        self.state.model = model
    }

    public func setStreamOptions(_ options: IPIStreamOptions) {
        self.streamOptions = options
    }

    public func setThinkingLevel(_ thinkingLevel: IPIThinkingLevel) {
        self.state.thinkingLevel = thinkingLevel
    }

    public func setTools(_ tools: [IPIAgentTool]) {
        self.state.tools = tools
    }

    public func replaceMessages(_ messages: [IPIAgentMessage]) {
        self.state.messages = messages
    }

    public func clearMessages() {
        self.state.messages.removeAll()
        self.state.streamMessage = nil
    }

    public func prompt(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        await self.runLoop(
            initialMessages: [
                .user(IPIUserMessage(text: trimmed)),
            ]
        )
    }

    public func prompt(_ message: IPIAgentMessage) async {
        await self.runLoop(initialMessages: [message])
    }

    public func continueConversation() async {
        guard !self.state.messages.isEmpty else {
            return
        }

        if case .assistant = self.state.messages[self.state.messages.endIndex - 1] {
            return
        }

        await self.runLoop(initialMessages: nil)
    }

    private func runLoop(initialMessages: [IPIAgentMessage]?) async {
        guard !self.state.isStreaming else {
            return
        }

        self.state.isStreaming = true
        self.state.streamMessage = nil
        self.state.error = nil
        self.emit(.agentStart)

        var shouldEmitTurnStart = true
        if let initialMessages {
            self.emit(.turnStart)
            shouldEmitTurnStart = false
            for message in initialMessages {
                self.emit(.messageStart(message: message))
                self.state.messages.append(message)
                self.emit(.messageEnd(message: message))
            }
        }

        var toolRounds = 0
        var toolCallCount = 0
        while !Task.isCancelled {
            if shouldEmitTurnStart {
                self.emit(.turnStart)
            }
            shouldEmitTurnStart = true

            let remainingCalls = max(0, self.executionOptions.maxToolCalls - toolCallCount)
            let allowTools = toolRounds < self.executionOptions.maxToolRounds && remainingCalls > 0
            let assistantMessage = await self.streamAssistantResponse(allowTools: allowTools)
            let assistantAgentMessage = IPIAgentMessage.assistant(assistantMessage)
            let toolCalls = assistantMessage.toolCalls

            var toolResults: [IPIToolResultMessage] = []
            if assistantMessage.stopReason != .error &&
                assistantMessage.stopReason != .aborted &&
                !toolCalls.isEmpty && !Task.isCancelled {
                toolResults = await self.executeToolCalls(toolCalls, limit: allowTools ? remainingCalls : 0)
                toolRounds += 1
                toolCallCount += min(toolCalls.count, allowTools ? remainingCalls : 0)
            }

            self.emit(
                .turnEnd(
                    message: assistantAgentMessage,
                    toolResults: toolResults
                )
            )

            if assistantMessage.stopReason == .error ||
                assistantMessage.stopReason == .aborted ||
                toolCalls.isEmpty || !allowTools {
                break
            }
        }

        self.state.isStreaming = false
        self.state.streamMessage = nil
        self.state.pendingToolCalls.removeAll()
        self.emit(.agentEnd(messages: self.state.messages))
    }

    private func streamAssistantResponse(allowTools: Bool) async -> IPIAssistantMessage {
        var resolvedStreamOptions = self.streamOptions
        resolvedStreamOptions.reasoning = self.state.thinkingLevel
        resolvedStreamOptions.allowToolCalls = allowTools

        let context = IPIContext(
            systemPrompt: self.state.systemPrompt + (allowTools ? "" : "\nTool budget reached. Do not call tools. Give your final answer now using the evidence already collected. Explain any missing evidence briefly."),
            messages: self.state.messages,
            tools: self.state.tools.map(\.definition)
        )

        let response = self.streamResponse(self.state.model, context, resolvedStreamOptions)

        var didStartMessage = false

        for await event in response {
            switch event {
            case .start(let partial):
                didStartMessage = true
                let partialMessage = IPIAgentMessage.assistant(partial)
                self.state.streamMessage = partialMessage
                self.emit(.messageStart(message: partialMessage))
            case .textStart(_, let partial),
                 .textDelta(_, _, let partial),
                 .textEnd(_, _, let partial),
                 .thinkingStart(_, let partial),
                 .thinkingDelta(_, _, let partial),
                 .thinkingEnd(_, _, let partial),
                 .toolCallStart(_, let partial),
                 .toolCallDelta(_, _, let partial),
                 .toolCallEnd(_, _, let partial):
                let partialMessage = IPIAgentMessage.assistant(partial)
                self.state.streamMessage = partialMessage
                self.emit(.messageUpdate(message: partialMessage, assistantMessageEvent: event))
            case .done(_, let message), .error(_, let message):
                let finalMessage = IPIAgentMessage.assistant(message)
                if !didStartMessage {
                    self.emit(.messageStart(message: finalMessage))
                }
                self.state.streamMessage = nil
                self.state.messages.append(finalMessage)
                self.state.error = message.errorMessage
                self.emit(.messageEnd(message: finalMessage))
                return message
            }
        }

        let finalMessage = await response.result()
        let agentMessage = IPIAgentMessage.assistant(finalMessage)
        self.state.streamMessage = nil
        self.state.messages.append(agentMessage)
        self.state.error = finalMessage.errorMessage
        self.emit(.messageEnd(message: agentMessage))
        return finalMessage
    }

    private func executeToolCalls(_ toolCalls: [IPIToolCall], limit: Int) async -> [IPIToolResultMessage] {
        // Record results in model call order even when requests finish out of order.
        await withTaskGroup(of: (Int, IPIToolResultMessage).self) { group in
            var results: [Int: IPIToolResultMessage] = [:]
            var nextIndex = 0
            let concurrency = self.executionOptions.maxConcurrentTools
            for _ in 0..<min(concurrency, toolCalls.count) {
                let index = nextIndex
                nextIndex += 1
                group.addTask { await (index, self.executeToolCall(toolCalls[index], allowed: index < limit)) }
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if nextIndex < toolCalls.count && !Task.isCancelled {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { await (index, self.executeToolCall(toolCalls[index], allowed: index < limit)) }
                }
            }
            let orderedResults = toolCalls.indices.compactMap { results[$0] }
            for result in orderedResults {
                let message = IPIAgentMessage.toolResult(result)
                self.state.messages.append(message)
                self.emit(.messageStart(message: message))
                self.emit(.messageEnd(message: message))
            }
            return orderedResults
        }
    }

    private func executeToolCall(_ call: IPIToolCall, allowed: Bool) async -> IPIToolResultMessage {
        self.state.pendingToolCalls.insert(call.id)
        defer { self.state.pendingToolCalls.remove(call.id) }
        self.emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, arguments: call.arguments))
        var result: IPIAgentToolResult
        var isError = true
        if !allowed {
            result = IPIAgentToolResult(content: [.text("Tool budget reached. Use the evidence already collected to answer now.")])
        } else if Task.isCancelled {
            result = IPIAgentToolResult(content: [.text("Cancelled")])
        } else if let tool = self.state.tools.first(where: { $0.name == call.name }) {
            do {
                let onUpdate: IPIAgentToolUpdateHandler = { [weak self] partial in
                    Task { @MainActor in
                        self?.emit(.toolExecutionUpdate(toolCallId: call.id, toolName: call.name,
                            arguments: call.arguments, partialResult: partial))
                    }
                }
                if let duration = self.executionOptions.maxToolDuration {
                    result = try await withThrowingTaskGroup(of: IPIAgentToolResult.self) { group in
                        group.addTask { try await tool.execute(call.id, call.arguments, onUpdate) }
                        group.addTask {
                            try await Task.sleep(for: duration)
                            throw ToolTimeBudgetExceeded()
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                } else {
                    result = try await tool.execute(call.id, call.arguments, onUpdate)
                }
                isError = false
            } catch {
                result = IPIAgentToolResult(content: [.text(error.localizedDescription)])
            }
        } else {
            result = IPIAgentToolResult(content: [.text("Tool not found: \(call.name)")])
        }
        self.emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: result, isError: isError))
        return IPIToolResultMessage(toolCallId: call.id, toolName: call.name,
            content: result.content, details: result.details, isError: isError)
    }

    private func emit(_ event: IPIAgentEvent) {
        for listener in self.listeners.values {
            listener(event)
        }
    }
}

private struct ToolTimeBudgetExceeded: LocalizedError {
    var errorDescription: String? {
        "Tool time budget exceeded. Use the evidence already collected, or try one alternative source."
    }
}
