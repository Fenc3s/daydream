import Foundation

struct ProviderModelCatalog: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
        var reasoning: OpenRouterReasoningCapability?
        var effort: Effort?
    }

    struct Effort: Decodable {
        var supported_levels: [String]?
    }

    static func fetch(provider: AIProvider, baseURL: String, apiKey: String) async throws -> Self {
        guard var url = URL(string: baseURL), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AppError.invalidBaseURL
        }
        url.append(path: "models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError.skillExecutionFailed("Model discovery failed (HTTP \(status)). Check authentication and the API URL. Saved models remain available.")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard !catalog.data.isEmpty else {
            throw AppError.skillExecutionFailed("The provider returned no models. Add a model ID manually or retry later.")
        }
        return catalog
    }
}

// Manual effort definitions take priority over provider catalog metadata.
enum ModelReasoning {
    static func modes(provider: AIProvider, model: String, capability: OpenRouterReasoningCapability?, manualEfforts: [ReasoningMode]? = nil) -> [ReasoningMode] {
        if let manualEfforts {
            return [.modelDefault] + ReasoningMode.allCases.filter { $0.effort != nil && manualEfforts.contains($0) }
        }
        if let capability {
            // An omitted effort list does not establish support for any explicit value.
            let efforts = capability.supportedEfforts ?? []
            return (provider == .openRouter && capability.mandatory != true ? [.modelDefault, .disabled] : [.modelDefault])
                + ReasoningMode.allCases.filter { $0.effort != nil && efforts.contains($0.rawValue) }
        }
        return [.modelDefault]
    }
}
