import Foundation

public typealias IPIAgentMessage = IPIMessage

public struct IPIAgentToolResult: Sendable, Equatable {
    public let content: [IPIToolResultContentBlock]
    public let details: JSONObject

    public init(
        content: [IPIToolResultContentBlock],
        details: JSONObject = [:]
    ) {
        self.content = content
        self.details = details
    }
}

public typealias IPIAgentToolUpdateHandler = @Sendable (IPIAgentToolResult) -> Void

public struct IPIAgentTool: Sendable {
    public let name: String
    public let label: String
    public let description: String
    public let parameters: JSONObject
    public let execute: @Sendable (_ toolCallId: String, _ arguments: JSONObject, _ onUpdate: IPIAgentToolUpdateHandler?) async throws -> IPIAgentToolResult

    public init(
        name: String,
        label: String,
        description: String,
        parameters: JSONObject = [:],
        execute: @escaping @Sendable (_ toolCallId: String, _ arguments: JSONObject, _ onUpdate: IPIAgentToolUpdateHandler?) async throws -> IPIAgentToolResult
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    public var definition: IPIToolDefinition {
        IPIToolDefinition(
            name: self.name,
            description: self.description,
            parameters: self.parameters
        )
    }
}

public struct IPIAgentState {
    public var systemPrompt: String
    public var model: IPIModel
    public var thinkingLevel: IPIThinkingLevel
    public var tools: [IPIAgentTool]
    public var messages: [IPIAgentMessage]
    public var isStreaming: Bool
    public var streamMessage: IPIAgentMessage?
    public var pendingToolCalls: Set<String>
    public var error: String?

    public init(
        systemPrompt: String,
        model: IPIModel,
        thinkingLevel: IPIThinkingLevel = .off,
        tools: [IPIAgentTool] = [],
        messages: [IPIAgentMessage] = [],
        isStreaming: Bool = false,
        streamMessage: IPIAgentMessage? = nil,
        pendingToolCalls: Set<String> = [],
        error: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamMessage = streamMessage
        self.pendingToolCalls = pendingToolCalls
        self.error = error
    }
}

public enum IPIAgentEvent {
    case agentStart
    case agentEnd(messages: [IPIAgentMessage])
    case turnStart
    case turnEnd(message: IPIAgentMessage, toolResults: [IPIToolResultMessage])
    case messageStart(message: IPIAgentMessage)
    case messageUpdate(message: IPIAgentMessage, assistantMessageEvent: IPIAssistantMessageEvent)
    case messageEnd(message: IPIAgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, arguments: JSONObject)
    case toolExecutionUpdate(toolCallId: String, toolName: String, arguments: JSONObject, partialResult: IPIAgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: IPIAgentToolResult, isError: Bool)
}
