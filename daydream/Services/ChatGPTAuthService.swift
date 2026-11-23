import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct ChatGPTAuthConfiguration: Equatable, Sendable {
    var authorizeEndpoint: URL
    var tokenEndpoint: URL
    var resource: String
    var scope: String
    var bootstrapClientID: String
    var agentNameHint: String

    static let `default` = ChatGPTAuthConfiguration(
        authorizeEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
        tokenEndpoint: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
        resource: "https://api.openai.com/v1",
        scope: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
        bootstrapClientID: "dynamic_agent_client",
        agentNameHint: "daydream"
    )
}

struct ChatGPTAuthSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var clientID: String
    var expiresAt: Date
    var scope: String?
    var email: String?
    var name: String?
    var subject: String?

    var displayIdentity: String {
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            return subject
        }
        return "ChatGPT Account"
    }

    var hasDirectPlanUsageScope: Bool {
        guard let scope = scope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty else {
            return true
        }
        return scope.split(whereSeparator: \.isWhitespace).contains("chatgpt.tokens.use.direct")
    }

    func isExpired(leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

struct ChatGPTAuthCallback: Equatable, Sendable {
    var code: String
    var state: String
    var clientID: String?
    var scope: String?
}

struct ChatGPTIDTokenClaims: Equatable, Sendable {
    var subject: String?
    var email: String?
    var name: String?
}

enum ChatGPTAuthError: LocalizedError, Equatable {
    case notSignedIn
    case sessionExpired(String?)
    case signInAlreadyInProgress
    case cancelled
    case callbackServerFailed(String)
    case callbackTimedOut
    case stateMismatch
    case authorizationDenied(String)
    case missingAuthorizationCode
    case tokenExchangeFailed(Int, String)
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with ChatGPT in Settings to use ChatGPT models."
        case .sessionExpired(let detail):
            if let detail, !detail.isEmpty {
                return "Your ChatGPT session expired (\(detail)). Please sign in again in Settings."
            }
            return "Your ChatGPT session expired. Please sign in again in Settings."
        case .signInAlreadyInProgress:
            return "A ChatGPT sign-in flow is already in progress."
        case .cancelled:
            return "ChatGPT sign-in was cancelled."
        case .callbackServerFailed(let detail):
            return "Could not start local OAuth callback listener: \(detail)"
        case .callbackTimedOut:
            return "ChatGPT sign-in timed out waiting for the browser callback."
        case .stateMismatch:
            return "ChatGPT sign-in failed security validation (OAuth state mismatch)."
        case .authorizationDenied(let message):
            return "ChatGPT sign-in was not completed: \(message)"
        case .missingAuthorizationCode:
            return "ChatGPT sign-in callback did not include an authorization code."
        case .tokenExchangeFailed(let statusCode, let message):
            let detail = message.isEmpty ? "Unexpected server response." : message
            return "ChatGPT token request failed (HTTP \(statusCode)): \(detail)"
        case .invalidTokenResponse:
            return "ChatGPT returned an invalid token response."
        }
    }
}

actor ChatGPTAuthService {
    private let credentialStore: any CredentialStoring
    private let configuration: ChatGPTAuthConfiguration
    private let logger: AppLogger
    private let urlSession: URLSession

    private var cachedSession: ChatGPTAuthSession?
    private var hasLoadedSession = false
    private var activeCallbackServer: LoopbackOAuthServer?
    private var activeRefreshTask: Task<ChatGPTAuthSession, Error>?

    init(
        credentialStore: any CredentialStoring,
        configuration: ChatGPTAuthConfiguration = .default,
        logger: AppLogger,
        urlSession: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.configuration = configuration
        self.logger = logger
        self.urlSession = urlSession
    }

    func currentSession() -> ChatGPTAuthSession? {
        if hasLoadedSession {
            return cachedSession
        }
        hasLoadedSession = true
        guard let raw = credentialStore.string(for: .chatGPTAuthSession),
              let data = raw.data(using: .utf8),
              let session = try? JSONDecoder().decode(ChatGPTAuthSession.self, from: data) else {
            cachedSession = nil
            return nil
        }
        cachedSession = session
        return session
    }

    func signOut() async {
        cancelSignIn()
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        cachedSession = nil
        hasLoadedSession = true
        credentialStore.setString("", for: .chatGPTAuthSession)
        await logger.log("auth", "Signed out of ChatGPT")
    }

    func cancelSignIn() {
        activeCallbackServer?.cancel()
        activeCallbackServer = nil
    }

    func signIn(
        timeout: Duration = .seconds(300),
        openURL: @escaping @Sendable (URL) -> Void = { url in
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    ) async throws -> ChatGPTAuthSession {
        guard activeCallbackServer == nil else {
            throw ChatGPTAuthError.signInAlreadyInProgress
        }

        let server = LoopbackOAuthServer()
        activeCallbackServer = server
        defer {
            server.cancel()
            if activeCallbackServer === server {
                activeCallbackServer = nil
            }
        }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let pkce = Self.generatePKCE()
        let state = Self.generateRandomToken()
        let nonce = Self.generateRandomToken()
        let hostID = loadOrCreateHostID()
        let existingClientID = loadPersistedClientID()

        let authorizationURL = Self.makeAuthorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            codeChallenge: pkce.challenge,
            hostID: hostID,
            existingClientID: existingClientID
        )

        await logger.log(
            "auth",
            "Starting Sign in with ChatGPT",
            metadata: [
                "redirect_uri": redirectURI,
                "reusing_client_id": existingClientID == nil ? "false" : "true",
            ]
        )

        openURL(authorizationURL)

        let callbackURL = try await server.waitForCallback(timeout: timeout)
        let callback: ChatGPTAuthCallback
        do {
            callback = try Self.parseCallbackQuery(from: callbackURL, expectedState: state)
        } catch let authError as ChatGPTAuthError {
            if case .authorizationDenied(let message) = authError,
               message.localizedCaseInsensitiveContains("invalid_client") {
                credentialStore.setString("", for: .chatGPTClientID)
            }
            throw authError
        }

        let resolvedClientID = Self.normalizedIssuedClientID(callback.clientID)
            ?? existingClientID
            ?? configuration.bootstrapClientID

        if let issuedClientID = Self.normalizedIssuedClientID(callback.clientID) {
            credentialStore.setString(issuedClientID, for: .chatGPTClientID)
        }

        let session = try await exchangeAuthorizationCode(
            code: callback.code,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURI,
            clientID: resolvedClientID,
            fallbackScope: callback.scope
        )
        persistSession(session)

        await logger.log(
            "auth",
            "Completed Sign in with ChatGPT",
            metadata: [
                "identity": session.displayIdentity,
                "direct_plan_scope": session.hasDirectPlanUsageScope ? "true" : "false",
            ]
        )

        return session
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session = currentSession() else {
            throw ChatGPTAuthError.notSignedIn
        }

        if !forceRefresh, !session.isExpired() {
            return session.accessToken
        }

        let refreshed = try await refreshSession(current: session)
        return refreshed.accessToken
    }

    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        fallbackScope: String? = nil
    ) async throws -> ChatGPTAuthSession {
        let tokenResponse = try await requestToken(parameters: [
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
            ("resource", configuration.resource),
        ])

        let finalClientID = Self.normalizedIssuedClientID(tokenResponse.clientID) ?? clientID
        if let issued = Self.normalizedIssuedClientID(finalClientID) {
            credentialStore.setString(issued, for: .chatGPTClientID)
        }

        let claims = tokenResponse.idToken.flatMap(Self.decodeIDTokenClaims)
        let expiresIn = TimeInterval(tokenResponse.expiresIn ?? 3600)
        return ChatGPTAuthSession(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            idToken: tokenResponse.idToken,
            clientID: finalClientID,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: tokenResponse.scope ?? fallbackScope,
            email: claims?.email,
            name: claims?.name,
            subject: claims?.subject
        )
    }

    func refreshSession(current session: ChatGPTAuthSession) async throws -> ChatGPTAuthSession {
        if let activeRefreshTask {
            return try await activeRefreshTask.value
        }

        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.sessionExpired("missing refresh token")
        }

        let task = Task<ChatGPTAuthSession, Error> {
            let tokenResponse = try await self.requestToken(parameters: [
                ("grant_type", "refresh_token"),
                ("client_id", session.clientID),
                ("refresh_token", refreshToken),
                ("resource", self.configuration.resource),
            ])

            let finalClientID = Self.normalizedIssuedClientID(tokenResponse.clientID) ?? session.clientID
            if let issued = Self.normalizedIssuedClientID(finalClientID) {
                self.credentialStore.setString(issued, for: .chatGPTClientID)
            }

            let claims = tokenResponse.idToken.flatMap(Self.decodeIDTokenClaims)
            let expiresIn = TimeInterval(tokenResponse.expiresIn ?? 3600)
            return ChatGPTAuthSession(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? session.refreshToken,
                idToken: tokenResponse.idToken ?? session.idToken,
                clientID: finalClientID,
                expiresAt: Date().addingTimeInterval(expiresIn),
                scope: tokenResponse.scope ?? session.scope,
                email: claims?.email ?? session.email,
                name: claims?.name ?? session.name,
                subject: claims?.subject ?? session.subject
            )
        }

        activeRefreshTask = task
        defer { activeRefreshTask = nil }

        do {
            let refreshed = try await task.value
            persistSession(refreshed)
            await logger.log("auth", "Refreshed ChatGPT access token")
            return refreshed
        } catch let authError as ChatGPTAuthError {
            if case .tokenExchangeFailed(let status, let message) = authError,
               status == 400 || status == 401 {
                if message.localizedCaseInsensitiveContains("invalid_client") {
                    credentialStore.setString("", for: .chatGPTClientID)
                }
                throw ChatGPTAuthError.sessionExpired(message)
            }
            throw authError
        }
    }

    private func persistSession(_ session: ChatGPTAuthSession) {
        cachedSession = session
        hasLoadedSession = true
        guard let data = try? JSONEncoder().encode(session),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        credentialStore.setString(string, for: .chatGPTAuthSession)
    }

    func loadOrCreateHostID() -> String {
        if let existing = credentialStore.string(for: .chatGPTHostID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = "urn:uuid:\(UUID().uuidString.lowercased())"
        credentialStore.setString(generated, for: .chatGPTHostID)
        return generated
    }

    private func loadPersistedClientID() -> String? {
        Self.normalizedIssuedClientID(credentialStore.string(for: .chatGPTClientID))
    }

    private func requestToken(parameters: [(String, String)]) async throws -> TokenEndpointResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedBody(parameters)

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard (200...299).contains(statusCode) else {
            let errorMessage = Self.parseOAuthErrorMessage(from: data)
            throw ChatGPTAuthError.tokenExchangeFailed(statusCode, errorMessage)
        }

        guard let decoded = try? JSONDecoder().decode(TokenEndpointResponse.self, from: data),
              !decoded.accessToken.isEmpty else {
            throw ChatGPTAuthError.invalidTokenResponse
        }
        return decoded
    }

    // MARK: - Pure OAuth / OIDC Helpers

    static func generatePKCE() -> (verifier: String, challenge: String) {
        let verifier = generateRandomToken(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return (verifier, challenge)
    }

    static func generateRandomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status == errSecSuccess {
            return base64URLEncode(Data(bytes))
        }
        return base64URLEncode(Data((UUID().uuidString + UUID().uuidString).utf8))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    static func normalizedIssuedClientID(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != ChatGPTAuthConfiguration.default.bootstrapClientID else {
            return nil
        }
        return trimmed
    }

    static func makeAuthorizationURL(
        configuration: ChatGPTAuthConfiguration = .default,
        redirectURI: String,
        state: String,
        nonce: String,
        codeChallenge: String,
        hostID: String,
        existingClientID: String?
    ) -> URL {
        var components = URLComponents(url: configuration.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        let issuedClientID = normalizedIssuedClientID(existingClientID)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: issuedClientID ?? configuration.bootstrapClientID),
        ]
        if issuedClientID == nil {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: configuration.agentNameHint))
        }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "resource", value: configuration.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
        components.queryItems = queryItems
        return components.url!
    }

    static func parseCallbackQuery(from url: URL, expectedState: String) throws -> ChatGPTAuthCallback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let lookup = Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { _, last in last })

        if let error = lookup["error"], !error.isEmpty {
            let description = lookup["error_description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (description?.isEmpty == false) ? "\(error): \(description!)" : error
            throw ChatGPTAuthError.authorizationDenied(detail)
        }

        guard let returnedState = lookup["state"], returnedState == expectedState else {
            throw ChatGPTAuthError.stateMismatch
        }

        guard let code = lookup["code"]?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            throw ChatGPTAuthError.missingAuthorizationCode
        }

        return ChatGPTAuthCallback(
            code: code,
            state: returnedState,
            clientID: lookup["client_id"],
            scope: lookup["scope"]
        )
    }

    static func decodeIDTokenClaims(_ idToken: String) -> ChatGPTIDTokenClaims? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        return ChatGPTIDTokenClaims(
            subject: json["sub"] as? String,
            email: json["email"] as? String,
            name: json["name"] as? String
        )
    }

    static func formURLEncodedBody(_ parameters: [(String, String)]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?/")
        let encoded = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func parseOAuthErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = json["error_description"] as? String, !description.isEmpty {
                return description
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
            if let errorObject = json["error"] as? [String: Any],
               let message = errorObject["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TokenEndpointResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var tokenType: String?
    var expiresIn: Int?
    var scope: String?
    var clientID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case clientID = "client_id"
    }
}

/// Minimal loopback HTTP server on `127.0.0.1` for receiving the Sign in with ChatGPT OAuth redirect.
final class LoopbackOAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Homer.daydream.chatgpt-oauth-callback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var isCancelled = false

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.isCancelled else {
                    continuation.resume(throwing: ChatGPTAuthError.cancelled)
                    return
                }

                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: .any
                )

                do {
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startContinuation = continuation

                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port?.rawValue else {
                                self.failStart(ChatGPTAuthError.callbackServerFailed("No ephemeral port assigned."))
                                return
                            }
                            self.succeedStart(port)
                        case .failed(let error):
                            let authError = ChatGPTAuthError.callbackServerFailed(error.localizedDescription)
                            self.failStart(authError)
                            self.finishCallback(.failure(authError))
                        case .cancelled:
                            self.failStart(ChatGPTAuthError.cancelled)
                            self.finishCallback(.failure(ChatGPTAuthError.cancelled))
                        default:
                            break
                        }
                    }

                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handleConnection(connection)
                    }

                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: ChatGPTAuthError.callbackServerFailed(error.localizedDescription))
                }
            }
        }
    }

    func waitForCallback(timeout: Duration) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeout()
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.pendingCallbackResult {
                        self.pendingCallbackResult = nil
                        continuation.resume(with: result)
                        return
                    }
                    if self.isCancelled {
                        continuation.resume(throwing: ChatGPTAuthError.cancelled)
                        return
                    }
                    self.callbackContinuation = continuation
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            guard !self.isCancelled else { return }
            self.isCancelled = true
            self.listener?.cancel()
            self.listener = nil
            self.failStart(ChatGPTAuthError.cancelled)
            self.finishCallback(.failure(ChatGPTAuthError.cancelled))
        }
    }

    private func timeout() {
        queue.async {
            guard !self.isCancelled else { return }
            self.isCancelled = true
            self.listener?.cancel()
            self.listener = nil
            self.finishCallback(.failure(ChatGPTAuthError.callbackTimedOut))
        }
    }

    private func succeedStart(_ port: UInt16) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: port)
    }

    private func failStart(_ error: Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(throwing: error)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else if pendingCallbackResult == nil {
            pendingCallbackResult = result
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data,
                  let requestText = String(data: data, encoding: .utf8),
                  let firstLine = requestText.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendResponse(status: "400 Bad Request", body: "Invalid request.", over: connection)
                return
            }

            let target = String(parts[1])
            guard let url = URL(string: "http://127.0.0.1\(target)"),
                  url.path == "/callback" else {
                self.sendResponse(status: "404 Not Found", body: "Not found.", over: connection)
                return
            }

            let hasError = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "error" }) ?? false

            let html = hasError
                ? Self.callbackHTML(
                    title: "Sign in not completed",
                    message: "You can close this tab and return to daydream."
                )
                : Self.callbackHTML(
                    title: "Signed in to daydream",
                    message: "Authentication succeeded. You can close this tab and return to daydream."
                )

            self.sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: html, over: connection) {
                self.listener?.cancel()
                self.listener = nil
                self.finishCallback(.success(url))
            }
        }
    }

    private func sendResponse(
        status: String,
        contentType: String = "text/plain; charset=utf-8",
        body: String,
        over connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(bodyData)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private static func callbackHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(title)</title>
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              background: #0f1115;
              color: #f3f5f8;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              margin: 0;
            }
            main {
              max-width: 420px;
              padding: 32px;
              border-radius: 16px;
              background: #171a21;
              border: 1px solid rgba(255, 255, 255, 0.08);
              text-align: center;
            }
            h1 { font-size: 20px; margin: 0 0 10px; }
            p { font-size: 14px; color: #a7b0be; margin: 0; line-height: 1.5; }
          </style>
        </head>
        <body>
          <main>
            <h1>\(title)</h1>
            <p>\(message)</p>
          </main>
        </body>
        </html>
        """
    }
}
