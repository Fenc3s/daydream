import Foundation

struct VerifiedReasoningCapability: Codable, Equatable, Sendable {
    static let currentDiscoveryVersion = 2
    private static let fractionalISO8601Style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let standardISO8601Style = Date.ISO8601FormatStyle()

    var discoveryVersion: Int? = currentDiscoveryVersion
    var efforts: [ReasoningMode]
    var checkedAt: String
    var endpoint: String
    var status: String

    func isFresh(for baseURL: String, now: Date = Date()) -> Bool {
        guard discoveryVersion == Self.currentDiscoveryVersion,
              endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let checked = (try? Self.fractionalISO8601Style.parse(checkedAt)) ?? (try? Self.standardISO8601Style.parse(checkedAt)) else {
            return false
        }
        let age = now.timeIntervalSince(checked)
        let lifetime: TimeInterval = ["verified", "auto_only"].contains(status) ? 7 * 24 * 60 * 60 : 15 * 60
        return age >= 0 && age < lifetime
    }

    static var localFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream/verified-reasoning.json")
    }

    static func stored(at url: URL = localFileURL) -> [String: Self] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return entries
    }

    static func store(_ entries: [String: Self], at url: URL = localFileURL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func localAndBundled() -> [String: Self] {
        var entries = bundled()
        for (model, entry) in stored() where entry.isFresh(for: entry.endpoint) || entries[model] == nil {
            entries[model] = entry
        }
        return entries
    }

    static func bundled() -> [String: Self] {
        guard let url = Bundle.main.url(forResource: "VerifiedReasoningCapabilities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return values
    }
}

// Discovery validates the same OpenAI-compatible streaming request used by commands.
// Results describe accepted API values, which may map to the same native effort.
enum ReasoningCapabilityDiscovery {
    private struct Response {
        var status: Int
        var text = ""
        var completed = false
        var media = false
    }

    static func discover(model: String, baseURL: String, apiKey: String) async -> VerifiedReasoningCapability {
        var result = VerifiedReasoningCapability(efforts: [], checkedAt: ISO8601DateFormatter().string(from: Date()), endpoint: baseURL, status: "unverified")
        let baseline = await probe(model: model, effort: nil, baseURL: baseURL, apiKey: apiKey)
        guard baseline.status == 200 else {
            result.status = baseline.status == 403 ? "region_blocked" : "route_unavailable"
            return result
        }
        guard baseline.completed, !baseline.media, baseline.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("323") else {
            result.status = "streaming_unverified"
            return result
        }
        let invalid = await probe(model: model, effort: "invalid_probe_value", baseURL: baseURL, apiKey: apiKey)
        guard invalid.status == 400 || invalid.status == 422 else {
            result.status = "parameter_not_validated"
            return result
        }
        let candidateModes = Array(ReasoningMode.allCases.filter { $0.effort != nil }.enumerated())
        let maxConcurrency = 4
        var acceptedIndices: Set<Int> = []

        await withTaskGroup(of: (Int, Bool).self) { group in
            var nextCursor = 0

            func enqueueNext() {
                guard nextCursor < candidateModes.count, !Task.isCancelled else { return }
                let (index, mode) = candidateModes[nextCursor]
                nextCursor += 1
                group.addTask {
                    guard !Task.isCancelled else { return (index, false) }
                    let response = await probe(model: model, effort: mode.effort, baseURL: baseURL, apiKey: apiKey)
                    let accepted = response.status == 200
                        && response.completed
                        && !response.media
                        && response.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("323")
                    return (index, accepted)
                }
            }

            for _ in 0..<min(maxConcurrency, candidateModes.count) {
                enqueueNext()
            }

            while let (index, accepted) = await group.next() {
                if accepted {
                    acceptedIndices.insert(index)
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueueNext()
            }
        }

        if Task.isCancelled { return result }
        result.efforts = candidateModes.compactMap { index, mode in
            acceptedIndices.contains(index) ? mode : nil
        }
        result.status = result.efforts.isEmpty ? "auto_only" : "verified"
        return result
    }

    private static func probe(model: String, effort: String?, baseURL: String, apiKey: String) async -> Response {
        guard var url = URL(string: baseURL), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return Response(status: 0) }
        url.append(path: "chat/completions")
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "What is 17 * 19? Reply with just the number."]], "stream": true, "max_tokens": 256]
        if let effort { body["reasoning_effort"] = effort }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return Response(status: status) }
            var result = Response(status: status)
            var byteCount = 0
            var stop = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                byteCount += line.utf8.count
                guard byteCount <= 2_000_000 else { return Response(status: 0) }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { result.completed = stop; return result }
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if event["error"] != nil { return Response(status: 502) }
                guard let choices = event["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                if choice["finish_reason"] as? String == "stop" { stop = true }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let text = delta["content"] as? String { result.text += text }
                if delta["images"] != nil || delta["audio"] != nil || delta["content"] is [[String: Any]] { result.media = true }
            }
            result.completed = stop
            return result
        } catch { return Response(status: 0) }
    }
}
