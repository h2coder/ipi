import Foundation
import IPI

struct ProviderConfiguration {
    let identifier: String
    let displayName: String
    let apiKey: String
    let baseURL: URL
    let defaultModel: String
}

struct AppConfiguration {
    let defaultProvider: String
    let providers: [String: ProviderConfiguration]

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let xcconfig = XCConfigValues.load(bundle: bundle)

        let modelscope = Self.providerConfiguration(
            identifier: "modelscope",
            nameKey: "PI_MODELSCOPE_NAME",
            apiKeyKey: "PI_MODELSCOPE_API_KEY",
            baseURLKey: "PI_MODELSCOPE_BASE_URL",
            defaultModelKey: "PI_MODELSCOPE_DEFAULT_MODEL",
            fallbackName: "ModelScope",
            fallbackBaseURL: URL(string: "https://api-inference.modelscope.cn/v1")!,
            fallbackModel: "Qwen/Qwen3.5-35B-A3B",
            xcconfig: xcconfig,
            bundle: bundle
        )

        let kimi = Self.providerConfiguration(
            identifier: "kimi",
            nameKey: "PI_KIMI_NAME",
            apiKeyKey: "PI_KIMI_API_KEY",
            baseURLKey: "PI_KIMI_BASE_URL",
            defaultModelKey: "PI_KIMI_DEFAULT_MODEL",
            fallbackName: "Kimi",
            fallbackBaseURL: URL(string: "https://api.moonshot.cn/v1")!,
            fallbackModel: "kimi-k2.5",
            xcconfig: xcconfig,
            bundle: bundle
        )

        let deepseek = Self.providerConfiguration(
            identifier: "deepseek",
            nameKey: "PI_DEEPSEEK_NAME",
            apiKeyKey: "PI_DEEPSEEK_API_KEY",
            baseURLKey: "PI_DEEPSEEK_BASE_URL",
            defaultModelKey: "PI_DEEPSEEK_DEFAULT_MODEL",
            fallbackName: "DeepSeek",
            fallbackBaseURL: URL(string: "https://api.deepseek.com")!,
            fallbackModel: "deepseek-flash",
            xcconfig: xcconfig,
            bundle: bundle
        )

        return AppConfiguration(
            defaultProvider: xcconfig.value(for: "PI_DEFAULT_PROVIDER", fallback: "modelscope"),
            providers: [
                modelscope.identifier: modelscope,
                kimi.identifier: kimi,
                deepseek.identifier: deepseek,
            ]
        )
    }

    var preferredProvider: ProviderConfiguration {
        self.providers[self.defaultProvider] ?? self.providers["modelscope"]!
    }

    func model(provider providerID: String, api: String = IPIAPI.openAICompletions) -> IPIModel {
        let provider = self.providers[providerID] ?? self.preferredProvider
        return IPIModel(
            id: provider.defaultModel,
            api: api,
            provider: provider.identifier,
            baseURL: provider.baseURL,
            reasoning: provider.identifier != "deepseek",
            input: [.text],
            maxTokens: 1_024
        )
    }

    func streamOptions(provider providerID: String) -> IPIStreamOptions {
        let provider = self.providers[providerID] ?? self.preferredProvider
        return IPIStreamOptions(
            temperature: 0,
            maxTokens: 1_024,
            apiKey: provider.apiKey,
            reasoning: nil,
            timeout: 120
        )
    }
}

private extension AppConfiguration {
    static func providerConfiguration(
        identifier: String,
        nameKey: String,
        apiKeyKey: String,
        baseURLKey: String,
        defaultModelKey: String,
        fallbackName: String,
        fallbackBaseURL: URL,
        fallbackModel: String,
        xcconfig: XCConfigValues,
        bundle: Bundle
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            identifier: identifier,
            displayName: xcconfig.value(for: nameKey, fallback: fallbackName),
            apiKey: xcconfig.value(for: apiKeyKey, fallback: identifier == "deepseek" ? xcconfig.value(for: "PI_DEEPSEEK_API_kEY", fallback: "") : ""),
            baseURL: self.urlValue(
                xcconfigKey: baseURLKey,
                fallback: fallbackBaseURL,
                xcconfig: xcconfig
            ),
            defaultModel: xcconfig.value(for: defaultModelKey, fallback: fallbackModel)
        )
    }

    static func urlValue(
        xcconfigKey: String,
        fallback: URL,
        xcconfig: XCConfigValues
    ) -> URL {
        let rawURL = xcconfig.value(
            for: xcconfigKey,
            fallback: fallback.absoluteString
        )

        return URL(string: rawURL) ?? fallback
    }
}

private struct XCConfigValues {
    private let resolvedValues: [String: String]

    static func load(bundle: Bundle) -> XCConfigValues {
        guard let url = bundle.url(forResource: "Secrets", withExtension: "xcconfig"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return XCConfigValues(resolvedValues: [:])
        }

        var rawValues: [String: String] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#"),
                  let separatorIndex = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rawValues[key] = value
        }

        var resolvedValues: [String: String] = [:]
        for key in rawValues.keys {
            resolvedValues[key] = Self.resolveValue(for: key, rawValues: rawValues, stack: [])
        }

        return XCConfigValues(resolvedValues: resolvedValues)
    }

    func value(for key: String, fallback: String) -> String {
        let value = self.resolvedValues[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    private static func resolveValue(
        for key: String,
        rawValues: [String: String],
        stack: Set<String>
    ) -> String {
        guard let rawValue = rawValues[key], !stack.contains(key) else {
            return rawValues[key] ?? ""
        }

        let pattern = #"\$\(([A-Za-z0-9_]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return rawValue
        }

        let nsRange = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        let matches = regex.matches(in: rawValue, range: nsRange)

        var resolved = rawValue
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: rawValue),
                  let replacementRange = Range(match.range(at: 0), in: resolved) else {
                continue
            }

            let token = String(rawValue[tokenRange])
            let replacement = Self.resolveValue(
                for: token,
                rawValues: rawValues,
                stack: stack.union([key])
            )
            resolved.replaceSubrange(replacementRange, with: replacement)
        }

        return resolved
    }
}
