public enum IPIAI {
    public static func stream(
        _ model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions = .init()
    ) -> IPIAssistantMessageEventStream {
        OpenAICompatibleProvider.stream(
            model: model,
            context: context,
            options: options
        )
    }

    public static func complete(
        _ model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions = .init()
    ) async -> IPIAssistantMessage {
        let stream = self.stream(
            model,
            context: context,
            options: options
        )
        return await stream.result()
    }

    public static func streamSimple(
        _ model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions = .init()
    ) -> IPIAssistantMessageEventStream {
        self.stream(
            model,
            context: context,
            options: options
        )
    }

    public static func completeSimple(
        _ model: IPIModel,
        context: IPIContext,
        options: IPIStreamOptions = .init()
    ) async -> IPIAssistantMessage {
        await self.complete(
            model,
            context: context,
            options: options
        )
    }
}
