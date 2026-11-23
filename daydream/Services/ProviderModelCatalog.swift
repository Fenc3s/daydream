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

    private struct ChatGPTModel: Decodable {
        var slug: String?
        var id: String?
        var displayName: String?
        var visibility: String?
        var supportedReasoningLevels: [ReasoningLevelEntry]?
        var defaultReasoningLevel: String?
        var reasoning: OpenRouterReasoningCapability?
        var effort: Effort?

        enum CodingKeys: String, CodingKey {
            case slug
            case id
            case displayName = "display_name"
            case visibility
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case reasoning
            case effort
        }

        enum ReasoningLevelEntry: Decodable {
            case string(String)
            case object(String)

            private enum CodingKeys: String, CodingKey {
                case effort
                case level
                case id
            }

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let value = try? single.decode(String.self) {
                    self = .string(value)
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let effort = try container.decodeIfPresent(String.self, forKey: .effort) {
                    self = .object(effort)
                } else if let level = try container.decodeIfPresent(String.self, forKey: .level) {
                    self = .object(level)
                } else if let id = try container.decodeIfPresent(String.self, forKey: .id) {
                    self = .object(id)
                } else {
                    self = .string("")
                }
            }

            var value: String {
                switch self {
                case .string(let s), .object(let s):
                    return s
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case models
    }

    init(data: [Model]) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let models = try container.decodeIfPresent([ChatGPTModel].self, forKey: .models) {
            let visible = models.filter { model in
                guard let visibility = model.visibility else { return true }
                return visibility == "list"
            }
            self.data = visible.compactMap { model in
                guard let identifier = (model.slug ?? model.id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !identifier.isEmpty else {
                    return nil
                }
                let levels = model.supportedReasoningLevels?
                    .map(\.value)
                    .filter { !$0.isEmpty }
                let reasoning: OpenRouterReasoningCapability?
                if let explicit = model.reasoning {
                    reasoning = explicit
                } else if let levels, !levels.isEmpty {
                    reasoning = OpenRouterReasoningCapability(
                        supportedEfforts: levels,
                        defaultEffort: model.defaultReasoningLevel
                    )
                } else {
                    reasoning = nil
                }
                return Model(id: identifier, reasoning: reasoning, effort: model.effort)
            }
            return
        }

        self.data = try container.decode([Model].self, forKey: .data)
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
