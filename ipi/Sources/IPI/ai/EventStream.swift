import Foundation

actor IPIResultBox<Result: Sendable> {
    private var storedResult: Result?
    private var continuations: [CheckedContinuation<Result, Never>] = []

    func resolve(_ result: Result) {
        guard self.storedResult == nil else {
            return
        }

        self.storedResult = result
        self.continuations.forEach { $0.resume(returning: result) }
        self.continuations.removeAll()
    }

    func value() async -> Result {
        if let storedResult {
            return storedResult
        }

        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
}

public final class IPIEventStream<Element: Sendable, Result: Sendable>: AsyncSequence, @unchecked Sendable {
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let resultBox = IPIResultBox<Result>()
    private let completion: @Sendable (Element) -> Result?

    public init(completion: @escaping @Sendable (Element) -> Result?) {
        var capturedContinuation: AsyncStream<Element>.Continuation?
        self.stream = AsyncStream<Element> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
        self.completion = completion
    }

    public func push(_ element: Element) {
        self.continuation.yield(element)

        if let result = self.completion(element) {
            let resultBox = self.resultBox
            Task {
                await resultBox.resolve(result)
            }
            self.continuation.finish()
        }
    }

    public func finish(with result: Result? = nil) {
        if let result {
            let resultBox = self.resultBox
            Task {
                await resultBox.resolve(result)
            }
        }
        self.continuation.finish()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        self.stream.makeAsyncIterator()
    }

    public func result() async -> Result {
        await self.resultBox.value()
    }
}

public typealias IPIAssistantMessageEventStream = IPIEventStream<IPIAssistantMessageEvent, IPIAssistantMessage>
