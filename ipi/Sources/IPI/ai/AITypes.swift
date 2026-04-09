import Foundation

public enum IPIAPI {
    public static let openAICompletions = "openai-completions"
}

public enum IPIInputCapability: String, Sendable, Equatable, Codable {
    case text
    case image
}

public enum IPIThinkingLevel: String, Sendable, Equatable, Codable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum IPIStopReason: String, Sendable, Equatable, Codable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

public struct IPIUsageCost: Sendable, Equatable, Codable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let total: Double

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        total: Double = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }

    public static let zero = IPIUsageCost()
}

public struct IPIUsage: Sendable, Equatable, Codable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let totalTokens: Int
    public let cost: IPIUsageCost

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        totalTokens: Int = 0,
        cost: IPIUsageCost = .zero
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens
        self.cost = cost
    }

    public static let zero = IPIUsage()
}

public struct IPIModel: Sendable, Equatable {
    public let id: String
    public let api: String
    public let provider: String
    public let baseURL: URL
    public let reasoning: Bool
    public let input: [IPIInputCapability]
    public let maxTokens: Int
    public let headers: [String: String]

    public init(
        id: String,
        api: String = IPIAPI.openAICompletions,
        provider: String,
        baseURL: URL,
        reasoning: Bool = false,
        input: [IPIInputCapability] = [.text],
        maxTokens: Int = 4_096,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.maxTokens = maxTokens
        self.headers = headers
    }
}

public struct IPIStreamOptions: Sendable, Equatable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var apiKey: String?
    public var reasoning: IPIThinkingLevel?
    public var additionalHeaders: [String: String]
    public var timeout: TimeInterval

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        apiKey: String? = nil,
        reasoning: IPIThinkingLevel? = nil,
        additionalHeaders: [String: String] = [:],
        timeout: TimeInterval = 120
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.apiKey = apiKey
        self.reasoning = reasoning
        self.additionalHeaders = additionalHeaders
        self.timeout = timeout
    }
}

public struct IPIImageContent: Sendable, Equatable, Codable {
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct IPIToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: JSONObject

    public init(id: String, name: String, arguments: JSONObject) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum IPIUserContentBlock: Sendable, Equatable, Codable {
    case text(String)
    case image(IPIImageContent)
}

public enum IPIAssistantContentBlock: Sendable, Equatable, Codable {
    case text(String)
    case thinking(String)
    case toolCall(IPIToolCall)
}

public enum IPIToolResultContentBlock: Sendable, Equatable, Codable {
    case text(String)
    case image(IPIImageContent)
}

public struct IPIUserMessage: Sendable, Equatable, Codable {
    public let content: [IPIUserContentBlock]
    public let timestamp: Date

    public init(content: [IPIUserContentBlock], timestamp: Date = .now) {
        self.content = content
        self.timestamp = timestamp
    }

    public init(text: String, timestamp: Date = .now) {
        self.init(content: [.text(text)], timestamp: timestamp)
    }
}

public struct IPIAssistantMessage: Sendable, Equatable, Codable {
    public let content: [IPIAssistantContentBlock]
    public let api: String
    public let provider: String
    public let model: String
    public let usage: IPIUsage
    public let stopReason: IPIStopReason
    public let errorMessage: String?
    public let timestamp: Date

    public init(
        content: [IPIAssistantContentBlock],
        api: String,
        provider: String,
        model: String,
        usage: IPIUsage = .zero,
        stopReason: IPIStopReason = .stop,
        errorMessage: String? = nil,
        timestamp: Date = .now
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public struct IPIToolResultMessage: Sendable, Equatable, Codable {
    public let toolCallId: String
    public let toolName: String
    public let content: [IPIToolResultContentBlock]
    public let details: JSONObject
    public let isError: Bool
    public let timestamp: Date

    public init(
        toolCallId: String,
        toolName: String,
        content: [IPIToolResultContentBlock],
        details: JSONObject = [:],
        isError: Bool,
        timestamp: Date = .now
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
    }
}

public enum IPIMessage: Sendable, Equatable, Codable {
    case user(IPIUserMessage)
    case assistant(IPIAssistantMessage)
    case toolResult(IPIToolResultMessage)

    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        }
    }

    public var timestamp: Date {
        switch self {
        case .user(let message):
            return message.timestamp
        case .assistant(let message):
            return message.timestamp
        case .toolResult(let message):
            return message.timestamp
        }
    }
}

public struct IPIToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let parameters: JSONObject

    public init(name: String, description: String, parameters: JSONObject = [:]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct IPIContext: Sendable, Equatable, Codable {
    public let systemPrompt: String?
    public let messages: [IPIMessage]
    public let tools: [IPIToolDefinition]

    public init(
        systemPrompt: String? = nil,
        messages: [IPIMessage],
        tools: [IPIToolDefinition] = []
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum IPIAssistantMessageEvent: Sendable, Equatable {
    case start(partial: IPIAssistantMessage)
    case textStart(contentIndex: Int, partial: IPIAssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: IPIAssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: IPIAssistantMessage)
    case thinkingStart(contentIndex: Int, partial: IPIAssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: IPIAssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: IPIAssistantMessage)
    case toolCallStart(contentIndex: Int, partial: IPIAssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: IPIAssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: IPIToolCall, partial: IPIAssistantMessage)
    case done(reason: IPIStopReason, message: IPIAssistantMessage)
    case error(reason: IPIStopReason, error: IPIAssistantMessage)
}

public extension IPIUserMessage {
    var plainText: String {
        self.content.compactMap {
            guard case .text(let text) = $0 else {
                return nil
            }

            return text
        }
        .joined(separator: "\n")
    }
}

public extension IPIAssistantMessage {
    var plainText: String {
        self.content.compactMap {
            guard case .text(let text) = $0 else {
                return nil
            }

            return text
        }
        .joined(separator: "\n")
    }

    var toolCalls: [IPIToolCall] {
        self.content.compactMap {
            guard case .toolCall(let toolCall) = $0 else {
                return nil
            }

            return toolCall
        }
    }
}

public extension IPIToolResultMessage {
    var plainText: String {
        self.content.compactMap {
            guard case .text(let text) = $0 else {
                return nil
            }

            return text
        }
        .joined(separator: "\n")
    }
}
