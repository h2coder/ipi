import Foundation

public struct DeepSeekSearchResult: Decodable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let summary: String
    public let date: String?
}

public struct DeepSeekFetchedPage: Decodable, Sendable {
    public let title: String
    public let content: String
}

public enum DeepSeekWebTools {
    public static func search(
        query: String,
        originalQuestion: String? = nil,
        count: Int = 5,
        baseURL: URL,
        apiKey: String
    ) async throws -> [DeepSeekSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(query.count), (1...50).contains(count) else {
            throw WebToolError.invalidSearchQuery
        }

        var body: [String: Any] = ["query": query, "count": count, "need_content": false]
        if let originalQuestion,
           (1...128).contains(originalQuestion.count),
           !originalQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["ori_question"] = originalQuestion
        }

        let data = try await self.post(path: "v1/tools/search", body: body, baseURL: baseURL, apiKey: apiKey)
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    public static func fetch(url: String, baseURL: URL, apiKey: String) async throws -> DeepSeekFetchedPage {
        guard url.count <= 8192,
              let parsed = URLComponents(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil,
              parsed.user == nil, parsed.password == nil else {
            throw WebToolError.invalidFetchURL
        }

        let data = try await self.post(
            path: "v1/tools/fetch", body: ["url": url], baseURL: baseURL, apiKey: apiKey
        )
        return try JSONDecoder().decode(DeepSeekFetchedPage.self, from: data)
    }

    private static func post(
        path: String, body: [String: Any], baseURL: URL, apiKey: String
    ) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw WebToolError.missingAPIKey }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebToolError.invalidResponse }
        guard http.statusCode == 200 else {
            let serverMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw WebToolError.requestFailed(status: http.statusCode, message: serverMessage ?? "Unknown error")
        }
        return data
    }
}

private struct SearchResponse: Decodable {
    let results: [DeepSeekSearchResult]
}

private enum WebToolError: LocalizedError {
    case invalidSearchQuery
    case invalidFetchURL
    case missingAPIKey
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidSearchQuery: "Search query must contain 1–128 characters; count must be 1–50."
        case .invalidFetchURL: "Fetch requires an HTTP or HTTPS URL without credentials."
        case .missingAPIKey: "Missing DeepSeek API key."
        case .invalidResponse: "Invalid DeepSeek tool response."
        case .requestFailed(let status, let message): "DeepSeek tool request failed (\(status)): \(message)"
        }
    }
}
