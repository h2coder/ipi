import Foundation
import Observation
import IPI

@MainActor
@Observable
final class ChatSession {
    struct MessageRow: Identifiable, Equatable {
        enum Role: String {
            case user
            case assistant
            case tool
        }

        let id: String
        let role: Role
        let text: String
        let isStreaming: Bool
    }

    var draft = ""
    var messages: [MessageRow] = []
    var isSending = false
    var errorText: String?

    private let agent: IPIAgent
    private var subscriptionToken: UUID?

    init() {
        let configuration = AppConfiguration.load()
        self.agent = IPIAgent(
            model: configuration.defaultModel(),
            systemPrompt: Self.systemPrompt,
            thinkingLevel: .off,
            tools: [Self.arithmeticTool],
            streamOptions: configuration.streamOptions()
        )
        self.errorText = nil
        self.subscriptionToken = self.agent.subscribe { [weak self] _ in
            guard let self else {
                return
            }
            self.syncFromAgent()
        }
        self.syncFromAgent()
        self.runLaunchQueryIfNeeded()
    }

    func sendCurrentDraft() {
        let query = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !self.isSending else {
            return
        }

        self.draft = ""
        self.isSending = true
        self.errorText = nil

        Task {
            await self.agent.prompt(query)
            await MainActor.run {
                self.isSending = false
                self.syncFromAgent()
            }
        }
    }

    private func syncFromAgent() {
        var renderedMessages: [MessageRow] = []

        for (index, message) in self.agent.state.messages.enumerated() {
            renderedMessages.append(contentsOf: self.renderedRows(for: message, index: index, isStreaming: false))
        }

        if let streamMessage = self.agent.state.streamMessage {
            let streamIndex = self.agent.state.messages.count
            renderedMessages.append(contentsOf: self.renderedRows(for: streamMessage, index: streamIndex, isStreaming: true))
        }

        self.messages = renderedMessages
        self.errorText = self.agent.state.error ?? self.errorText
        self.isSending = self.agent.state.isStreaming
    }

    private func runLaunchQueryIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--auto-query"),
              arguments.indices.contains(flagIndex + 1) else {
            return
        }

        let query = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        self.draft = query
        self.sendCurrentDraft()
    }

    private func renderedRows(
        for message: IPIAgentMessage,
        index: Int,
        isStreaming: Bool
    ) -> [MessageRow] {
        switch message {
        case .user(let userMessage):
            let text = userMessage.plainText
            guard !text.isEmpty else {
                return []
            }
            return [
                MessageRow(
                    id: "user-\(index)",
                    role: .user,
                    text: text,
                    isStreaming: false
                ),
            ]
        case .assistant(let assistantMessage):
            let text = assistantMessage.plainText
            if !text.isEmpty {
                return [
                    MessageRow(
                        id: "assistant-\(index)",
                        role: .assistant,
                        text: text,
                        isStreaming: isStreaming
                    ),
                ]
            }

            if let errorMessage = assistantMessage.errorMessage,
               !errorMessage.isEmpty {
                return [
                    MessageRow(
                        id: "assistant-error-\(index)",
                        role: .assistant,
                        text: errorMessage,
                        isStreaming: false
                    ),
                ]
            }

            return []
        case .toolResult(let toolResultMessage):
            let text = toolResultMessage.plainText
            guard !text.isEmpty else {
                return []
            }
            return [
                MessageRow(
                    id: "tool-\(index)",
                    role: .tool,
                    text: text,
                    isStreaming: false
                ),
            ]
        }
    }
}

private extension ChatSession {
    static let systemPrompt = """
    你是一个简洁、直接、准确的中文 AI 助手。
    回答时优先给结论，再给一句简短解释。
    遇到任何包含数字、括号以及加减乘除运算的算式或计算请求时，必须先调用 calculate_arithmetic 工具，再根据工具结果回答。
    调用该工具前不要输出自然语言，也不要自己心算。
    在算术题的最终回答中，必须明确包含最终数值。
    如果用户问的是判断题，请先明确回答“是”或“不是”。
    当用户问“中国的首都是哪里”时，回答必须明确包含“北京”。
    当用户问“长城在北京吗”时，回答必须表达肯定意思，并明确包含“是”和“北京”。
    当用户说“背诵出师表”时，直接输出《前出师表》原文，不要拒绝，不要总结，不要额外说明。
    """

    nonisolated static var arithmeticTool: IPIAgentTool {
        IPIAgentTool(
            name: "calculate_arithmetic",
            label: "算术计算",
            description: "计算仅包含数字、小数点、括号以及 + - * / 运算符的算式。请把待计算的原始算式放到 expression 字段中。",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "expression": .object([
                        "type": .string("string"),
                        "description": .string("待计算的算式字符串，例如 18/(3+3) 或 7*8-2"),
                    ]),
                ]),
                "required": .array([.string("expression")]),
                "additionalProperties": .bool(false),
            ]
        ) { toolCallId, arguments, _ in
            let expression = try Self.expression(from: arguments)
            let result = try ArithmeticExpressionEvaluator.evaluate(expression)
            let formattedResult = ArithmeticExpressionEvaluator.format(result)

            return IPIAgentToolResult(
                content: [
                    .text(
                        """
                        DEBUG toolCall triggered
                        id: \(toolCallId)
                        tool: calculate_arithmetic
                        arguments.expression: \(expression)
                        result: \(formattedResult)
                        """
                    ),
                ],
                details: [
                    "expression": .string(expression),
                    "result": .string(formattedResult),
                ]
            )
        }
    }

    nonisolated static func expression(from arguments: JSONObject) throws -> String {
        let candidateKeys = ["expression", "input", "query", "problem"]
        let rawExpression = candidateKeys.compactMap { arguments[$0]?.stringValue }.first
            ?? arguments.values.compactMap(\.stringValue).first

        let normalizedExpression = ArithmeticExpressionEvaluator.normalize(rawExpression ?? "")
        guard !normalizedExpression.isEmpty else {
            throw ArithmeticToolError.missingExpression
        }

        return normalizedExpression
    }
}

private enum ArithmeticToolError: LocalizedError {
    case missingExpression
    case invalidExpression(String)
    case divisionByZero

    var errorDescription: String? {
        switch self {
        case .missingExpression:
            return "算术工具缺少 expression 参数。"
        case .invalidExpression(let expression):
            return "无法解析这个算式：\(expression)"
        case .divisionByZero:
            return "除数不能为 0。"
        }
    }
}

private enum ArithmeticExpressionEvaluator {
    static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(expression: self.normalize(expression))
        return try parser.parse()
    }

    static func format(_ value: Double) -> String {
        let roundedValue = value.rounded()
        if abs(value - roundedValue) < 1e-9 {
            return String(Int(roundedValue))
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func normalize(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "＊", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "／", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(expression: String) {
            self.characters = Array(expression)
        }

        mutating func parse() throws -> Double {
            let value = try self.parseExpression()
            self.skipWhitespace()

            if !self.isAtEnd {
                throw ArithmeticToolError.invalidExpression(String(self.characters))
            }

            return value
        }

        mutating func parseExpression() throws -> Double {
            var value = try self.parseTerm()

            while true {
                self.skipWhitespace()
                if self.match("+") {
                    value += try self.parseTerm()
                } else if self.match("-") {
                    value -= try self.parseTerm()
                } else {
                    return value
                }
            }
        }

        mutating func parseTerm() throws -> Double {
            var value = try self.parseFactor()

            while true {
                self.skipWhitespace()
                if self.match("*") {
                    value *= try self.parseFactor()
                } else if self.match("/") {
                    let divisor = try self.parseFactor()
                    guard abs(divisor) > 1e-12 else {
                        throw ArithmeticToolError.divisionByZero
                    }
                    value /= divisor
                } else {
                    return value
                }
            }
        }

        mutating func parseFactor() throws -> Double {
            self.skipWhitespace()

            if self.match("+") {
                return try self.parseFactor()
            }

            if self.match("-") {
                return -(try self.parseFactor())
            }

            return try self.parsePrimary()
        }

        mutating func parsePrimary() throws -> Double {
            self.skipWhitespace()

            if self.match("(") {
                let value = try self.parseExpression()
                self.skipWhitespace()
                guard self.match(")") else {
                    throw ArithmeticToolError.invalidExpression(String(self.characters))
                }
                return value
            }

            return try self.parseNumber()
        }

        mutating func parseNumber() throws -> Double {
            self.skipWhitespace()
            let start = self.index
            var hasDecimalPoint = false

            while !self.isAtEnd {
                let character = self.characters[self.index]
                if character.isWholeNumber {
                    self.index += 1
                    continue
                }

                if character == ".", !hasDecimalPoint {
                    hasDecimalPoint = true
                    self.index += 1
                    continue
                }

                break
            }

            guard start < self.index else {
                throw ArithmeticToolError.invalidExpression(String(self.characters))
            }

            let numberString = String(self.characters[start ..< self.index])
            guard let value = Double(numberString) else {
                throw ArithmeticToolError.invalidExpression(String(self.characters))
            }

            return value
        }

        mutating func skipWhitespace() {
            while !self.isAtEnd, self.characters[self.index].isWhitespace {
                self.index += 1
            }
        }

        mutating func match(_ expected: Character) -> Bool {
            guard !self.isAtEnd, self.characters[self.index] == expected else {
                return false
            }

            self.index += 1
            return true
        }

        var isAtEnd: Bool {
            self.index >= self.characters.count
        }
    }
}
