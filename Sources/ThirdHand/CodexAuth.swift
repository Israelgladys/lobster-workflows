import AppKit
import CryptoKit
import Foundation
import Network

struct CodexTokens: Codable, Equatable {
    var access: String
    var refresh: String
    var expires: Date
    var accountId: String
    var subject: String
    var email: String?
}

struct CodexAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// ChatGPT sign-in for the Codex backend: browser OAuth with PKCE and a loopback callback.
enum CodexAuth {
    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    nonisolated static let callbackPort: UInt16 = 1455
    nonisolated static let redirectURI = "http://localhost:1455/auth/callback"

    struct PKCE {
        let verifier: String
        let challenge: String
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    nonisolated static func makePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    nonisolated static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(string: issuer + "/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: CodexClient.originator)
        ]
        return components.url!
    }

    nonisolated static func claims(_ token: String?) -> [String: Any] {
        let parts = token?.split(separator: ".") ?? []
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    /// Account and subject must stay the same across refreshes; a different account means signing in again.
    nonisolated static func normalize(_ raw: [String: Any], previous: CodexTokens? = nil, now: Date = Date()) throws -> CodexTokens {
        let identity = claims(raw["id_token"] as? String)
        let access = claims(raw["access_token"] as? String)
        func account(_ claims: [String: Any]) -> String? {
            (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
                ?? claims["chatgpt_account_id"] as? String
        }
        let accountId = account(identity) ?? account(access) ?? previous?.accountId
        let subject = identity["sub"] as? String ?? access["sub"] as? String ?? previous?.subject
        guard let subject, !subject.isEmpty, previous == nil || previous?.subject == subject else {
            throw CodexAuthError(message: "Sign in with ChatGPT again to confirm your account.")
        }
        guard let accessToken = raw["access_token"] as? String, let accountId,
              previous == nil || previous?.accountId == accountId else {
            throw CodexAuthError(message: "ChatGPT did not return a usable Codex account.")
        }
        guard let refresh = raw["refresh_token"] as? String ?? previous?.refresh else {
            throw CodexAuthError(message: "ChatGPT did not return a refresh token. Sign in again.")
        }
        let lifetime = (raw["expires_in"] as? Double) ?? 3600
        return CodexTokens(access: accessToken, refresh: refresh, expires: now.addingTimeInterval(lifetime),
                           accountId: accountId, subject: subject,
                           email: identity["email"] as? String ?? previous?.email)
    }

    nonisolated static func tokenRequest(_ params: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: issuer + "/oauth/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = params.merging(["client_id": clientID]) { a, _ in a }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, which form decoding reads as a space.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    nonisolated static func requestTokens(_ params: [String: String], previous: CodexTokens? = nil,
                                          session: URLSession) async throws -> CodexTokens {
        let (data, response) = try await session.data(for: tokenRequest(params))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError(message: "ChatGPT authorization expired or was declined. Sign in again.")
        }
        return try normalize(raw, previous: previous)
    }

    /// Opens the browser and waits for the loopback callback.
    @MainActor
    static func signIn(session: URLSession = .shared,
                       open: (URL) -> Void = { NSWorkspace.shared.open($0) }) async throws -> CodexTokens {
        let pkce = makePKCE()
        let state = base64URL(randomBytes(32))
        let server = CodexCallbackServer(state: state)
        try await server.start()
        defer { server.stop() }
        open(authorizeURL(pkce: pkce, state: state))
        let code = try await AsyncTimeout.run(seconds: 300, message: "ChatGPT sign-in timed out. Try again.") {
            try await server.code()
        }
        return try await requestTokens(["grant_type": "authorization_code", "code": code,
                                        "redirect_uri": redirectURI, "code_verifier": pkce.verifier], session: session)
    }
}

/// Serializes token refresh so concurrent requests never spend the same refresh token twice.
actor CodexCredentials {
    private var tokens: CodexTokens
    private var refreshing: Task<CodexTokens, Error>?
    private let session: URLSession
    private let persist: @Sendable (CodexTokens) throws -> Void

    init(tokens: CodexTokens, session: URLSession = .shared,
         persist: @escaping @Sendable (CodexTokens) throws -> Void = { try KeychainHelper.saveCodexTokens($0) }) {
        self.tokens = tokens
        self.session = session
        self.persist = persist
    }

    func current(now: Date = Date()) async throws -> CodexTokens {
        if tokens.expires > now.addingTimeInterval(60) { return tokens }
        if let refreshing { return try await refreshing.value }
        let previous = tokens
        let session = session
        let task = Task {
            try await CodexAuth.requestTokens(["grant_type": "refresh_token", "refresh_token": previous.refresh],
                                              previous: previous, session: session)
        }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        try persist(fresh)
        Log.info("Codex token refreshed")
        return fresh
    }
}

/// Minimal loopback HTTP listener for the OAuth redirect.
final class CodexCallbackServer: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "thirdhand.codex-callback")
    private var listener: NWListener?
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var starting: CheckedContinuation<Void, Error>?

    init(state: String) { self.state = state }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: CodexAuth.callbackPort)!) }
        catch { throw CodexAuthError(message: "Port \(CodexAuth.callbackPort) is unavailable. Close other ChatGPT sign-in windows and try again.") }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        // State updates arrive on `queue`, which also owns `starting`.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.starting = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let starting = self.starting else { return }
                    switch state {
                    case .ready: self.starting = nil; starting.resume()
                    case .failed, .cancelled:
                        self.starting = nil
                        starting.resume(throwing: CodexAuthError(message: "Port \(CodexAuth.callbackPort) is unavailable. Close other ChatGPT sign-in windows and try again."))
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finish(.failure(CancellationError()))
        }
    }

    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.waiter = continuation }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (status, message, outcome) = Self.evaluate(request: request, state: self.state)
            if let outcome { self.finish(outcome) }
            let html = "<!doctype html><meta charset=utf-8><title>Third Hand</title><body style=\"font:15px -apple-system;padding:40px\">\(message)</body>"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Returns the HTTP status, page text, and sign-in outcome (nil for unrelated requests).
    static func evaluate(request: String, state: String) -> (String, String, Result<String, Error>?) {
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://localhost" + target), components.path == "/auth/callback" else {
            return ("404 Not Found", "Not found.", nil)
        }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        if let error = items["error"] {
            let detail = items["error_description"] ?? error
            return ("200 OK", "Sign-in failed. You can close this tab.", .failure(CodexAuthError(message: "ChatGPT sign-in failed: \(detail.prefix(200))")))
        }
        guard items["state"] == state else {
            return ("400 Bad Request", "Sign-in could not be verified. Start again from Third Hand.",
                    .failure(CodexAuthError(message: "ChatGPT sign-in could not be verified. Try again.")))
        }
        guard let code = items["code"], !code.isEmpty else {
            return ("400 Bad Request", "Sign-in failed. Start again from Third Hand.",
                    .failure(CodexAuthError(message: "ChatGPT did not return an authorization code.")))
        }
        return ("200 OK", "Signed in to Third Hand. You can close this tab.", .success(code))
    }
}
