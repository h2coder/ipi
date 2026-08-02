# IPI

IPI is a native Swift agent SDK for iOS. It gives your app a small, concurrency-safe building block for conversations with OpenAI-compatible language models, including:

- streamed text and reasoning output;
- multi-turn conversation state;
- model-driven tool calls and tool execution;
- text and image input;
- usage and stop-reason metadata; and
- low-level access when you do not need the agent loop.

IPI is designed to be used from SwiftUI or UIKit applications. It uses Swift Concurrency and has no third-party package dependencies.

> The package currently supports iOS 17+ and macOS 15+. Its built-in transport speaks the OpenAI Chat Completions-compatible HTTP format.

## How it works

There are two ways to use IPI:

1. `IPIAgent` is the high-level API. It owns the conversation, streams assistant updates, runs tools, appends tool results, and continues the loop until the model finishes.
2. `IPIAI` is the low-level API. You provide an `IPIContext` and consume the response stream yourself.

The main types are:

| Type | Purpose |
| --- | --- |
| `IPIModel` | Describes a model, provider, and OpenAI-compatible base URL |
| `IPIStreamOptions` | Supplies the API key, timeout, sampling, reasoning, and extra headers |
| `IPIContext` | Contains the system prompt, conversation messages, and tool definitions |
| `IPIAgent` | Manages a stateful conversation and the tool-use loop |
| `IPIAgentTool` | Defines a tool the model can call |
| `IPIAssistantMessageEvent` | Describes streaming text, reasoning, tool-call, completion, and error events |

## Installation

### Swift Package Manager

In Xcode, choose **File > Add Package Dependencies**, then enter:

```text
https://github.com/h2coder/ipi.git
```

Select the version or branch you want to use, add the `IPI` product to your app target, and import it where needed:

```swift
import IPI
```

For a `Package.swift` dependency, use the repository's `main` branch while the project is under active development, or replace it with a released version when one is available:

```swift
dependencies: [
    .package(url: "https://github.com/h2coder/ipi.git", branch: "main")
]
```

Then add `"IPI"` to the target's dependencies.

## Quick start: a streaming agent

The following example creates an agent, listens for streamed assistant updates, and sends a prompt. Put the code in a `@MainActor` type such as a SwiftUI observable model or view controller.

```swift
import Foundation
import IPI

@MainActor
final class ChatSession {
    private let agent: IPIAgent
    private var subscriptionToken: UUID?

    init(apiKey: String) {
        let model = IPIModel(
            id: "gpt-4o-mini",
            provider: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        self.agent = IPIAgent(
            model: model,
            systemPrompt: "You are a concise and helpful assistant.",
            streamOptions: IPIStreamOptions(
                apiKey: apiKey,
                temperature: 0.2
            )
        )

        self.subscriptionToken = self.agent.subscribe { [weak self] event in
            guard let self else { return }

            switch event {
            case .messageUpdate(let message, _):
                if case .assistant(let assistant) = message {
                    // Use this partial value to update the UI while it streams.
                    print(assistant.plainText)
                }
            case .agentEnd:
                print("Conversation turn finished")
            case .toolExecutionStart(_, let name, _):
                print("Running tool: \(name)")
            default:
                break
            }
        }
    }

    deinit {
        if let subscriptionToken {
            self.agent.unsubscribe(subscriptionToken)
        }
    }

    func send(_ text: String) async {
        await self.agent.prompt(text)
    }

    var messages: [IPIAgentMessage] {
        self.agent.state.messages
    }

    var isStreaming: Bool {
        self.agent.state.isStreaming
    }
}
```

From a SwiftUI view, call the session from a task:

```swift
Button("Send") {
    Task {
        await session.send("Explain actors in Swift in one paragraph.")
    }
}
```

`agent.state.streamMessage` contains the current partial assistant message while a response is in progress. The completed messages are appended to `agent.state.messages`.

## Configure another OpenAI-compatible provider

`IPIModel` separates provider configuration from request options. Point `baseURL` at the provider's v1-compatible API root; IPI appends `/chat/completions` to it.

```swift
let model = IPIModel(
    id: "Qwen/Qwen3.5-35B-A3B",
    provider: "modelscope",
    baseURL: URL(string: "https://api-inference.modelscope.cn/v1")!,
    reasoning: true,
    maxTokens: 1_024
)

let options = IPIStreamOptions(
    apiKey: apiKey,
    reasoning: .medium,
    timeout: 120
)

let agent = IPIAgent(
    model: model,
    thinkingLevel: .medium,
    streamOptions: options
)
```

The built-in transport sends a bearer token, JSON request bodies, streaming Server-Sent Events, and standard function tools. Provider-specific headers can be supplied with `model.headers` or `options.additionalHeaders`.

## Add tools

Tools let the model request an operation that your app performs locally or through your own service. The tool's JSON Schema is sent to the model. When the model calls it, IPI executes the closure, adds the result to the conversation, and asks the model to continue.

```swift
let weatherTool = IPIAgentTool(
    name: "get_weather",
    label: "Get weather",
    description: "Return the current weather for a city.",
    parameters: [
        "type": .string("object"),
        "properties": .object([
            "city": .object([
                "type": .string("string"),
                "description": .string("The city to look up")
            ])
        ]),
        "required": .array([.string("city")]),
        "additionalProperties": .bool(false)
    ]
) { _, arguments, _ in
    let city = arguments["city"]?.stringValue ?? "unknown"

    // Call your weather service here.
    return IPIAgentToolResult(
        content: [.text("The weather in \(city) is sunny.")],
        details: ["city": .string(city)]
    )
}

let agent = IPIAgent(
    model: model,
    tools: [weatherTool],
    streamOptions: options
)
```

For long-running work, use the tool's `onUpdate` closure to emit partial results. Throwing from the closure produces an error tool result and the agent reports the failed execution through `.toolExecutionEnd`.

Useful agent events include:

- `.messageStart`, `.messageUpdate`, and `.messageEnd` for conversation messages;
- `.toolExecutionStart`, `.toolExecutionUpdate`, and `.toolExecutionEnd` for tools;
- `.turnStart` and `.turnEnd` for each model/tool cycle; and
- `.agentStart` and `.agentEnd` for the complete prompt operation.

## Send images

For a model that accepts images, include `.image` content and declare `.image` in the model's input capabilities. Image data is supplied as base64.

```swift
let model = IPIModel(
    id: "vision-model",
    provider: "openai-compatible-provider",
    baseURL: URL(string: "https://example.com/v1")!,
    input: [.text, .image]
)

let message = IPIUserMessage(content: [
    .text("What is in this image?"),
    .image(IPIImageContent(data: base64JPEG, mimeType: "image/jpeg"))
])

await agent.prompt(.user(message))
```

## Use the low-level streaming API

Use `IPIAI` when you want to own message storage, tool dispatch, or rendering yourself.

```swift
let context = IPIContext(
    systemPrompt: "You are a helpful assistant.",
    messages: [
        .user(IPIUserMessage(text: "Give me three names for a coffee shop."))
    ]
)

let stream = IPIAI.stream(
    model,
    context: context,
    options: IPIStreamOptions(apiKey: apiKey)
)

for await event in stream {
    switch event {
    case .textDelta(_, let delta, _):
        print(delta, terminator: "")
    case .thinkingDelta(_, let delta, _):
        print("[thinking] \(delta)", terminator: "")
    case .toolCallEnd(_, let toolCall, _):
        print("Tool requested: \(toolCall.name)")
    case .done(_, let message), .error(_, let message):
        print("\nFinished with \(message.stopReason)")
    default:
        break
    }
}

let finalMessage = await stream.result()
print(finalMessage.plainText)
```

For a non-streaming call, use `await IPIAI.complete(...)`. The returned `IPIAssistantMessage` includes `plainText`, `thinkingText`, `toolCalls`, `usage`, `stopReason`, and an optional `errorMessage`.

## Conversation and message types

The agent stores messages as `IPIAgentMessage` (an alias for `IPIMessage`):

```swift
switch message {
case .user(let userMessage):
    print(userMessage.plainText)
case .assistant(let assistantMessage):
    print(assistantMessage.plainText)
    print(assistantMessage.thinkingText)
    print(assistantMessage.toolCalls)
case .toolResult(let result):
    print(result.toolName, result.plainText)
}
```

You can seed or restore a conversation with `IPIAgent.replaceMessages(_:)`, clear it with `clearMessages()`, or send a structured message with `prompt(_ message: IPIAgentMessage)`. `continueConversation()` resumes a conversation when its latest message is not an assistant response.

## API keys and production architecture

IPI sends the API key from `IPIStreamOptions` directly to the configured endpoint. Do not embed a production provider secret in an iOS app unless your threat model explicitly allows it: app binaries can be inspected and keys can be extracted.

For a production application, a safer design is:

1. keep the provider credential on your server;
2. have the app call an authenticated service you control; and
3. point IPI at that service if it exposes the OpenAI-compatible `/v1/chat/completions` contract.

For prototypes, local development, or providers that issue restricted user-scoped keys, load the key from a secure configuration mechanism such as the Keychain and never commit it to the repository.

## Errors and observability

Network, decoding, and provider errors are represented in the assistant result with `stopReason == .error` and an `errorMessage`. `IPIAgent.state.error` mirrors the latest agent error. The provider also logs request and response status information through `OSLog`; avoid logging sensitive prompts or credentials in production builds.

## Requirements

- iOS 17 or later
- macOS 15 or later when using the package on macOS
- Swift 6.1 or later
- An OpenAI Chat Completions-compatible endpoint

## Development

Clone the repository and open the `ipi` directory as a Swift package in Xcode, or run the package tests from the command line:

```bash
cd ipi
swift test
```

The repository also contains `ai_assitant_app`, a sample SwiftUI app that demonstrates a chat UI, provider configuration, streaming state, and a calculator tool.

## License

No license file is currently included in this repository. Add a license before distributing IPI as an open-source dependency.
