import Foundation

struct OpenRouterReasoningCapability: Decodable, Equatable, Sendable {
    var mandatory: Bool?
    var defaultEnabled: Bool?
    var supportedEfforts: [String]?
    var defaultEffort: String?

    enum CodingKeys: String, CodingKey {
        case mandatory
        case defaultEnabled = "default_enabled"
        case supportedEfforts = "supported_efforts"
        case defaultEffort = "default_effort"
    }
}

final class AIClient {
    private let logger: AppLogger
    private let openRouterCapabilityStore = OpenRouterCapabilityStore()

    init(logger: AppLogger) {
        self.logger = logger
    }

    func refreshOpenRouterModelCapabilities(
        baseURL: String,
        apiKey: String
    ) async throws -> [String: OpenRouterReasoningCapability] {
        let capabilities = try await openRouterCapabilityStore.capabilities(
            baseURL: baseURL,
            apiKey: apiKey,
            forceRefresh: true
        )
        await logger.log(
            "api",
            "Refreshed OpenRouter model capabilities",
            metadata: ["models": "\(capabilities.count)"]
        )
        return capabilities
    }

    func generateText(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        chatGPTBaseURL: String = AppSettings.default.chatGPTBaseURL,
        chatGPTAccessToken: String = "",
        chatGPTTokenRefresher: (@Sendable () async throws -> String)? = nil,
        model: String,
        prompt: String
    ) async throws -> String {
        try await generateText(
            provider: provider,
            openRouterBaseURL: openRouterBaseURL,
            openRouterAPIKey: openRouterAPIKey,
            deepSeekBaseURL: deepSeekBaseURL,
            deepSeekAPIKey: deepSeekAPIKey,
            chatGPTBaseURL: chatGPTBaseURL,
            chatGPTAccessToken: chatGPTAccessToken,
            chatGPTTokenRefresher: chatGPTTokenRefresher,
            model: model,
            messages: [
                .init(role: "user", content: prompt)
            ]
        )
    }

    func generateText(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        chatGPTBaseURL: String = AppSettings.default.chatGPTBaseURL,
        chatGPTAccessToken: String = "",
        chatGPTTokenRefresher: (@Sendable () async throws -> String)? = nil,
        model: String,
        messages: [AIClientMessage],
        reasoningMode: ReasoningMode? = nil
    ) async throws -> String {
        if provider == .chatGPT {
            var output = ""
            for try await delta in streamText(
                provider: provider,
                openRouterBaseURL: openRouterBaseURL,
                openRouterAPIKey: openRouterAPIKey,
                deepSeekBaseURL: deepSeekBaseURL,
                deepSeekAPIKey: deepSeekAPIKey,
                chatGPTBaseURL: chatGPTBaseURL,
                chatGPTAccessToken: chatGPTAccessToken,
                chatGPTTokenRefresher: chatGPTTokenRefresher,
                model: model,
                messages: messages,
                reasoningMode: reasoningMode
            ) {
                output += delta
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppError.noResponseText
            }
            return trimmed
        }

        let effectiveReasoningMode = await effectiveReasoningMode(
            provider: provider,
            openRouterBaseURL: openRouterBaseURL,
            openRouterAPIKey: openRouterAPIKey,
            model: model,
            requested: reasoningMode
        )
        let baseURLString: String
        let apiKey: String

        switch provider {
        case .openRouter:
            baseURLString = openRouterBaseURL
            apiKey = openRouterAPIKey
        case .deepSeek:
            baseURLString = deepSeekBaseURL
            apiKey = deepSeekAPIKey
        case .chatGPT:
            baseURLString = chatGPTBaseURL
            apiKey = chatGPTAccessToken
        }

        guard var url = URL(string: baseURLString) else {
            throw AppError.invalidBaseURL
        }

        url.append(path: "chat/completions")

        var requestBody = ChatCompletionsRequest(
            model: model,
            messages: messages.map { ChatMessage(role: $0.role, content: .string($0.content)) },
            thinking: thinkingConfiguration(provider: provider, model: model, override: providerReasoningEnabled(for: effectiveReasoningMode)),
            reasoning: reasoningConfiguration(provider: provider, mode: effectiveReasoningMode),
            reasoningEffort: reasoningEffort(provider: provider, model: model, mode: effectiveReasoningMode)
        )
        if provider == .openRouter, effectiveReasoningMode?.effort != nil { requestBody.provider = .init() }
        let encodedBody = try JSONEncoder().encode(requestBody)

        await logger.log(
            "api",
            "Sending request",
            metadata: [
                "provider": provider.rawValue,
                "url": url.absoluteString,
                "model": model,
                "reasoning": reasoningDescription(for: effectiveReasoningMode),
                "message_count": "\(messages.count)",
                "prompt_preview": String(messages.last?.content.prefix(240) ?? ""),
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if provider == .openRouter {
            request.setValue("daydream", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("daydream", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = encodedBody

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        await logger.log(
            "api",
            "Received response",
            metadata: [
                "status": "\(statusCode)",
                "body_preview": String(decoding: data.prefix(600), as: UTF8.self),
            ]
        )

        guard (200...299).contains(statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.choices.first?.message.resolvedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AppError.noResponseText
        }

        return text
    }

    func streamText(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        chatGPTBaseURL: String = AppSettings.default.chatGPTBaseURL,
        chatGPTAccessToken: String = "",
        chatGPTTokenRefresher: (@Sendable () async throws -> String)? = nil,
        model: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        streamText(
            provider: provider,
            openRouterBaseURL: openRouterBaseURL,
            openRouterAPIKey: openRouterAPIKey,
            deepSeekBaseURL: deepSeekBaseURL,
            deepSeekAPIKey: deepSeekAPIKey,
            chatGPTBaseURL: chatGPTBaseURL,
            chatGPTAccessToken: chatGPTAccessToken,
            chatGPTTokenRefresher: chatGPTTokenRefresher,
            model: model,
            messages: [
                .init(role: "user", content: prompt)
            ]
        )
    }

    func streamText(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        chatGPTBaseURL: String = AppSettings.default.chatGPTBaseURL,
        chatGPTAccessToken: String = "",
        chatGPTTokenRefresher: (@Sendable () async throws -> String)? = nil,
        model: String,
        messages: [AIClientMessage],
        reasoningMode: ReasoningMode? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    try Task.checkCancellation()
                    var effectiveReasoningMode = await effectiveReasoningMode(
                        provider: provider,
                        openRouterBaseURL: openRouterBaseURL,
                        openRouterAPIKey: openRouterAPIKey,
                        model: model,
                        requested: reasoningMode
                    )
                    var didRetryMandatoryReasoning = false
                    var didRetryAuthRefresh = false
                    var activeChatGPTToken = chatGPTAccessToken

                    while true {
                        try Task.checkCancellation()
                        let request: URLRequest
                        if provider == .chatGPT {
                            request = try await makeResponsesRequest(
                                baseURLString: chatGPTBaseURL,
                                accessToken: activeChatGPTToken,
                                model: model,
                                messages: messages,
                                reasoningMode: effectiveReasoningMode
                            )
                        } else {
                            request = try await makeChatCompletionsRequest(
                                provider: provider,
                                openRouterBaseURL: openRouterBaseURL,
                                openRouterAPIKey: openRouterAPIKey,
                                deepSeekBaseURL: deepSeekBaseURL,
                                deepSeekAPIKey: deepSeekAPIKey,
                                model: model,
                                messages: messages,
                                stream: true,
                                reasoningMode: effectiveReasoningMode
                            )
                        }
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

                        guard (200...299).contains(statusCode) else {
                            let responseBody = try await responseBody(from: bytes)
                            await logger.log(
                                "api",
                                "Received streaming error response",
                                metadata: [
                                    "status": "\(statusCode)",
                                    "body_preview": String(responseBody.prefix(600)),
                                ]
                            )

                            if provider == .chatGPT,
                               statusCode == 401,
                               !didRetryAuthRefresh,
                               let chatGPTTokenRefresher {
                                didRetryAuthRefresh = true
                                activeChatGPTToken = try await chatGPTTokenRefresher()
                                await logger.log(
                                    "api",
                                    "Retrying ChatGPT request after token refresh",
                                    metadata: ["model": model]
                                )
                                continue
                            }

                            if provider == .openRouter,
                               effectiveReasoningMode == .disabled,
                               !didRetryMandatoryReasoning,
                               requiresMandatoryReasoning(responseBody) {
                                didRetryMandatoryReasoning = true
                                effectiveReasoningMode = .modelDefault
                                await openRouterCapabilityStore.markReasoningMandatory(
                                    model: model,
                                    baseURL: openRouterBaseURL
                                )
                                await logger.log(
                                    "api",
                                    "Retrying with the model's required reasoning default",
                                    metadata: ["model": model]
                                )
                                continue
                            }

                            throw AIClientError.serverResponse(
                                statusCode: statusCode,
                                message: serverErrorMessage(from: responseBody)
                            )
                        }

                        if provider == .chatGPT {
                            var emittedAnyDelta = false
                            for try await line in bytes.lines {
                                try Task.checkCancellation()
                                guard line.hasPrefix("data:") else { continue }
                                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !payload.isEmpty else { continue }
                                if payload == "[DONE]" { break }
                                guard let data = payload.data(using: .utf8),
                                      let event = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: data) else {
                                    continue
                                }
                                switch event.type {
                                case "response.output_text.delta":
                                    if let delta = event.delta, !delta.isEmpty {
                                        emittedAnyDelta = true
                                        continuation.yield(delta)
                                    }
                                case "response.failed", "error":
                                    let message = event.error?.message
                                        ?? event.response?.error?.message
                                        ?? "ChatGPT returned an error during streaming."
                                    throw AIClientError.serverResponse(statusCode: statusCode, message: message)
                                case "response.completed":
                                    if !emittedAnyDelta,
                                       let fallbackText = event.response?.resolvedOutputText,
                                       !fallbackText.isEmpty {
                                        continuation.yield(fallbackText)
                                    }
                                default:
                                    break
                                }
                            }
                        } else {
                            for try await line in bytes.lines {
                                try Task.checkCancellation()
                                guard line.hasPrefix("data:") else { continue }
                                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !payload.isEmpty, payload != "[DONE]" else {
                                    if payload == "[DONE]" { break }
                                    continue
                                }
                                guard let data = payload.data(using: .utf8) else { continue }
                                let decoded = try JSONDecoder().decode(ChatCompletionsStreamResponse.self, from: data)
                                for choice in decoded.choices {
                                    if let content = choice.delta.resolvedText, !content.isEmpty {
                                        continuation.yield(content)
                                    }
                                }
                            }
                        }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func makeResponsesRequest(
        baseURLString: String,
        accessToken: String,
        model: String,
        messages: [AIClientMessage],
        reasoningMode: ReasoningMode?
    ) async throws -> URLRequest {
        guard var url = URL(string: baseURLString) else {
            throw AppError.invalidBaseURL
        }
        url.append(path: "responses")

        let inputMessages = messages.map { message in
            let role = message.role == "system" ? "developer" : message.role
            return ResponsesInputMessage(role: role, content: message.content)
        }
        let reasoning = reasoningMode?.effort.map { ResponsesRequest.Reasoning(effort: $0) }
        let requestBody = ResponsesRequest(
            model: model,
            input: inputMessages,
            store: false,
            stream: true,
            reasoning: reasoning
        )

        await logger.log(
            "api",
            "Sending streaming request",
            metadata: [
                "provider": AIProvider.chatGPT.rawValue,
                "url": url.absoluteString,
                "model": model,
                "reasoning": reasoningDescription(for: reasoningMode),
                "message_count": "\(messages.count)",
                "prompt_preview": String(messages.last?.content.prefix(240) ?? ""),
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(requestBody)
        return request
    }

    private func makeChatCompletionsRequest(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        model: String,
        messages: [AIClientMessage],
        stream: Bool,
        reasoningMode: ReasoningMode?
    ) async throws -> URLRequest {
        let baseURLString: String
        let apiKey: String

        switch provider {
        case .openRouter:
            baseURLString = openRouterBaseURL
            apiKey = openRouterAPIKey
        case .deepSeek:
            baseURLString = deepSeekBaseURL
            apiKey = deepSeekAPIKey
        case .chatGPT:
            baseURLString = AppSettings.default.chatGPTBaseURL
            apiKey = ""
        }

        guard var url = URL(string: baseURLString) else {
            throw AppError.invalidBaseURL
        }

        url.append(path: "chat/completions")

        var requestBody = ChatCompletionsRequest(
            model: model,
            messages: messages.map { ChatMessage(role: $0.role, content: .string($0.content)) },
            stream: stream,
            thinking: thinkingConfiguration(provider: provider, model: model, override: providerReasoningEnabled(for: reasoningMode)),
            reasoning: reasoningConfiguration(provider: provider, mode: reasoningMode),
            reasoningEffort: reasoningEffort(provider: provider, model: model, mode: reasoningMode)
        )

        await logger.log(
            "api",
            stream ? "Sending streaming request" : "Sending request",
            metadata: [
                "provider": provider.rawValue,
                "url": url.absoluteString,
                "model": model,
                "reasoning": reasoningDescription(for: reasoningMode),
                "message_count": "\(messages.count)",
                "prompt_preview": String(messages.last?.content.prefix(240) ?? ""),
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if provider == .openRouter {
            request.setValue("daydream", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("daydream", forHTTPHeaderField: "X-Title")
        }
        if provider == .openRouter, reasoningMode?.effort != nil { requestBody.provider = .init() }
        request.httpBody = try JSONEncoder().encode(requestBody)
        return request
    }

    private func thinkingConfiguration(
        provider: AIProvider,
        model: String,
        override: Bool?
    ) -> ChatCompletionsRequest.Thinking? {
        guard provider == .deepSeek else { return nil }
        if let override {
            return override ? .enabled : .disabled
        }
        return nil
    }

    private func reasoningConfiguration(
        provider: AIProvider,
        mode: ReasoningMode?
    ) -> ChatCompletionsRequest.Reasoning? {
        guard provider == .openRouter, let mode else { return nil }
        switch mode {
        case .disabled:
            return ChatCompletionsRequest.Reasoning(enabled: false)
        case .modelDefault:
            return nil
        case .noEffort, .minimal, .low, .medium, .high, .xhigh, .max:
            return ChatCompletionsRequest.Reasoning(effort: mode.effort)
        }
    }

    private func reasoningEffort(provider: AIProvider, model: String, mode: ReasoningMode?) -> String? {
        guard provider != .openRouter else { return nil }
        return mode?.effort
    }

    private func providerReasoningEnabled(for mode: ReasoningMode?) -> Bool? {
        guard let mode else { return nil }
        return mode == .modelDefault ? nil : mode != .disabled
    }

    private func reasoningDescription(for mode: ReasoningMode?) -> String {
        guard let mode else { return "provider_default" }
        return mode.rawValue
    }

    private func effectiveReasoningMode(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        model: String,
        requested: ReasoningMode?
    ) async -> ReasoningMode? {
        if provider == .deepSeek {
            return requested ?? .disabled
        }
        guard provider == .openRouter, let requested else {
            return requested
        }

        do {
            let capabilities = try await openRouterCapabilityStore.capabilities(
                baseURL: openRouterBaseURL,
                apiKey: openRouterAPIKey
            )
            guard capabilities[model]?.mandatory == true else {
                return requested
            }
            if requested == .disabled {
                await logger.log(
                    "api",
                    "Using the model's required reasoning default",
                    metadata: ["model": model]
                )
                return .modelDefault
            }
            return requested
        } catch {
            await logger.log(
                "api",
                "Could not refresh OpenRouter model capabilities",
                metadata: ["error": error.localizedDescription]
            )
            return requested
        }
    }

    private func responseBody(from bytes: URLSession.AsyncBytes, limit: Int = 16_384) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.utf8.count >= limit {
                break
            }
        }
        return String(body.prefix(limit))
    }

    private func requiresMandatoryReasoning(_ responseBody: String) -> Bool {
        let message = serverErrorMessage(from: responseBody).lowercased()
        return message.contains("reasoning is mandatory") && message.contains("cannot be disabled")
    }

    private func serverErrorMessage(from responseBody: String) -> String {
        guard let data = responseBody.data(using: .utf8),
              let response = try? JSONDecoder().decode(ChatCompletionsErrorResponse.self, from: data) else {
            return responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response.error.message
    }
}

private enum AIClientError: LocalizedError {
    case serverResponse(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .serverResponse(let statusCode, let message):
            let detail = message.isEmpty ? "The server returned an error." : message
            return "AI request failed (HTTP \(statusCode)): \(detail)"
        }
    }
}

private struct ChatCompletionsErrorResponse: Decodable {
    var error: ErrorDetail

    struct ErrorDetail: Decodable {
        var message: String
    }
}

private actor OpenRouterCapabilityStore {
    private struct CacheEntry {
        var capabilities: [String: OpenRouterReasoningCapability]
        var expiresAt: Date
    }

    private struct ModelsResponse: Decodable {
        var data: [Model]

        struct Model: Decodable {
            var id: String
            var reasoning: OpenRouterReasoningCapability?
        }
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLifetime: TimeInterval = 60 * 60

    func capabilities(
        baseURL: String,
        apiKey: String,
        forceRefresh: Bool = false
    ) async throws -> [String: OpenRouterReasoningCapability] {
        let cacheKey = normalizedBaseURL(baseURL)
        if !forceRefresh,
           let cached = cache[cacheKey],
           cached.expiresAt > Date() {
            return cached.capabilities
        }

        guard var url = URL(string: baseURL) else {
            throw AppError.invalidBaseURL
        }
        url.append(path: "models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ChatCompletionsErrorResponse.self, from: data))?.error.message
                ?? String(decoding: data.prefix(600), as: UTF8.self)
            throw AIClientError.serverResponse(statusCode: statusCode, message: message)
        }

        let models = try JSONDecoder().decode(ModelsResponse.self, from: data).data
        let capabilities = Dictionary(
            uniqueKeysWithValues: models.compactMap { model in
                model.reasoning.map { (model.id, $0) }
            }
        )
        cache[cacheKey] = CacheEntry(
            capabilities: capabilities,
            expiresAt: Date().addingTimeInterval(cacheLifetime)
        )
        return capabilities
    }

    func markReasoningMandatory(model: String, baseURL: String) {
        let cacheKey = normalizedBaseURL(baseURL)
        var entry = cache[cacheKey] ?? CacheEntry(
            capabilities: [:],
            expiresAt: Date().addingTimeInterval(cacheLifetime)
        )
        var capability = entry.capabilities[model] ?? OpenRouterReasoningCapability()
        capability.mandatory = true
        capability.defaultEnabled = true
        entry.capabilities[model] = capability
        entry.expiresAt = Date().addingTimeInterval(cacheLifetime)
        cache[cacheKey] = entry
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct AIClientMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String
}

private struct ChatCompletionsRequest: Codable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool? = nil
    var thinking: Thinking?
    var reasoning: Reasoning?
    var reasoningEffort: String?
    var provider: Routing? = nil

    struct Routing: Codable {
        var require_parameters: Bool = true
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case thinking
        case reasoning
        case reasoningEffort = "reasoning_effort"
        case provider
    }

    struct Thinking: Codable {
        var type: String

        static let enabled = Thinking(type: "enabled")
        static let disabled = Thinking(type: "disabled")
    }

    struct Reasoning: Codable {
        var enabled: Bool?
        var effort: String?

        init(enabled: Bool? = nil, effort: String? = nil) {
            self.enabled = enabled
            self.effort = effort
        }
    }
}

private struct ChatCompletionsStreamResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var delta: Delta
    }

    struct Delta: Decodable {
        var content: MessageContent?

        var resolvedText: String? {
            guard let content else { return nil }
            switch content {
            case .string(let value):
                return value
            case .parts(let parts):
                let text = parts.compactMap(\.text).joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
        }
    }
}

private struct ChatMessage: Codable {
    var role: String
    var content: MessageContent
}

private struct ChatCompletionsResponse: Decodable {
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: MessageContent?

        var resolvedText: String? {
            guard let content else { return nil }
            switch content {
            case .string(let value):
                return value
            case .parts(let parts):
                let text = parts.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
    }
}

private enum MessageContent: Codable {
    case string(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        self = .parts(try container.decode([ContentPart].self))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private struct ContentPart: Codable {
    var type: String?
    var text: String?
    var imageUrl: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }

    struct ImageURL: Codable {
        var url: String
    }
}

private struct ResponsesRequest: Encodable {
    var model: String
    var input: [ResponsesInputMessage]
    var store: Bool
    var stream: Bool
    var reasoning: Reasoning?

    struct Reasoning: Encodable {
        var effort: String
    }
}

private struct ResponsesInputMessage: Encodable {
    var role: String
    var content: String
}

private struct ResponsesStreamEvent: Decodable {
    var type: String?
    var delta: String?
    var error: ErrorDetail?
    var response: CompletedResponse?

    struct ErrorDetail: Decodable {
        var message: String?
    }

    struct CompletedResponse: Decodable {
        var error: ErrorDetail?
        var output: [OutputItem]?

        var resolvedOutputText: String? {
            guard let output else { return nil }
            let chunks = output.flatMap { item in
                (item.content ?? []).compactMap { part in
                    part.text
                }
            }
            let joined = chunks.joined()
            return joined.isEmpty ? nil : joined
        }
    }

    struct OutputItem: Decodable {
        var content: [OutputContentPart]?
    }

    struct OutputContentPart: Decodable {
        var text: String?
    }
}
