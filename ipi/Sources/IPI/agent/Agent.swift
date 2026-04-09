import Foundation

@MainActor
public final class IPIAgent {
    public private(set) var state: IPIAgentState

    private var streamOptions: IPIStreamOptions
    private var listeners: [UUID: (IPIAgentEvent) -> Void] = [:]

    public init(
        initialState: IPIAgentState,
        streamOptions: IPIStreamOptions = .init()
    ) {
        self.state = initialState
        self.streamOptions = streamOptions
    }

    public convenience init(
        model: IPIModel,
        systemPrompt: String = "",
        thinkingLevel: IPIThinkingLevel = .off,
        tools: [IPIAgentTool] = [],
        messages: [IPIAgentMessage] = [],
        streamOptions: IPIStreamOptions = .init()
    ) {
        self.init(
            initialState: IPIAgentState(
                systemPrompt: systemPrompt,
                model: model,
                thinkingLevel: thinkingLevel,
                tools: tools,
                messages: messages
            ),
            streamOptions: streamOptions
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

        while true {
            if shouldEmitTurnStart {
                self.emit(.turnStart)
            }
            shouldEmitTurnStart = true

            let assistantMessage = await self.streamAssistantResponse()
            let assistantAgentMessage = IPIAgentMessage.assistant(assistantMessage)
            let toolCalls = assistantMessage.toolCalls

            var toolResults: [IPIToolResultMessage] = []
            if assistantMessage.stopReason != .error &&
                assistantMessage.stopReason != .aborted &&
                !toolCalls.isEmpty {
                toolResults = await self.executeToolCalls(toolCalls)
            }

            self.emit(
                .turnEnd(
                    message: assistantAgentMessage,
                    toolResults: toolResults
                )
            )

            if assistantMessage.stopReason == .error ||
                assistantMessage.stopReason == .aborted ||
                toolCalls.isEmpty {
                break
            }
        }

        self.state.isStreaming = false
        self.state.streamMessage = nil
        self.state.pendingToolCalls.removeAll()
        self.emit(.agentEnd(messages: self.state.messages))
    }

    private func streamAssistantResponse() async -> IPIAssistantMessage {
        var resolvedStreamOptions = self.streamOptions
        resolvedStreamOptions.reasoning = self.state.thinkingLevel == .off ? nil : self.state.thinkingLevel

        let context = IPIContext(
            systemPrompt: self.state.systemPrompt,
            messages: self.state.messages,
            tools: self.state.tools.map(\.definition)
        )

        let response = IPIAI.streamSimple(
            self.state.model,
            context: context,
            options: resolvedStreamOptions
        )

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

    private func executeToolCalls(_ toolCalls: [IPIToolCall]) async -> [IPIToolResultMessage] {
        var toolResults: [IPIToolResultMessage] = []

        for toolCall in toolCalls {
            self.state.pendingToolCalls.insert(toolCall.id)
            self.emit(
                .toolExecutionStart(
                    toolCallId: toolCall.id,
                    toolName: toolCall.name,
                    arguments: toolCall.arguments
                )
            )

            let tool = self.state.tools.first { $0.name == toolCall.name }
            var result = IPIAgentToolResult(content: [.text("Tool not found: \(toolCall.name)")])
            var isError = true

            if let tool {
                do {
                    result = try await tool.execute(toolCall.id, toolCall.arguments) { [weak self] partialResult in
                        guard let self else {
                            return
                        }
                        Task { @MainActor in
                            self.emit(
                                .toolExecutionUpdate(
                                    toolCallId: toolCall.id,
                                    toolName: toolCall.name,
                                    arguments: toolCall.arguments,
                                    partialResult: partialResult
                                )
                            )
                        }
                    }
                    isError = false
                } catch {
                    result = IPIAgentToolResult(
                        content: [.text(error.localizedDescription)]
                    )
                    isError = true
                }
            }

            self.emit(
                .toolExecutionEnd(
                    toolCallId: toolCall.id,
                    toolName: toolCall.name,
                    result: result,
                    isError: isError
                )
            )

            let toolResultMessage = IPIToolResultMessage(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                content: result.content,
                details: result.details,
                isError: isError
            )
            let agentMessage = IPIAgentMessage.toolResult(toolResultMessage)

            self.state.messages.append(agentMessage)
            toolResults.append(toolResultMessage)
            self.emit(.messageStart(message: agentMessage))
            self.emit(.messageEnd(message: agentMessage))
            self.state.pendingToolCalls.remove(toolCall.id)
        }

        return toolResults
    }

    private func emit(_ event: IPIAgentEvent) {
        for listener in self.listeners.values {
            listener(event)
        }
    }
}
