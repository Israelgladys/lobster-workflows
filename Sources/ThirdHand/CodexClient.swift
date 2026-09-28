import Foundation

struct CodexServiceError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct CodexFunctionCall: Equatable {
    let callID: String
    let name: String
    let arguments: String
}

struct CodexResponse {
    /// Raw output items, resent verbatim as input on the next turn (the backend stores nothing).
    let output: [[String: Any]]

    var functionCalls: [CodexFunctionCall] {
        output.compactMap { item in
            guard item["type"] as? String == "function_call", let callID = item["call_id"] as? String,
                  let name = item["name"] as? String else { return nil }
            return CodexFunctionCall(callID: callID, name: name, arguments: item["arguments"] as? String ?? "{}")
        }
    }

    var text: String {
        output.filter { $0["type"] as? String == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}

/// ChatGPT-authenticated Responses API on the Codex backend.
@MainActor
final class CodexClient {
    nonisolated static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    nonisolated static let originator = "third_hand"
    nonisolated static let defaultModel = "gpt-6-sol"
    nonisolated static var model: String { UserDefaults.standard.string(forKey: "CodexModel") ?? defaultModel }

    private let credentials: CodexCredentials
    private let session: URLSession
    let model: String

    init(credentials: CodexCredentials, session: URLSession = .shared, model: String = CodexClient.model) {
        self.credentials = credentials
        self.session = session
        self.model = model
    }

    nonisolated static func requestBody(model: String, instructions: String, input: [[String: Any]],
                                        tools: [[String: Any]], effort: String) -> [String: Any] {
        ["model": model, "instructions": instructions, "input": input, "tools": tools,
         "tool_choice": "auto", "parallel_tool_calls": false, "store": false, "stream": true,
         "reasoning": ["effort": effort], "include": ["reasoning.encrypted_content"]]
    }

    func respond(instructions: String, input: [[String: Any]], tools: [[String: Any]],
                 effort: String = "low") async throws -> CodexResponse {
        let tokens = try await credentials.current()
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.originator, forHTTPHeaderField: "originator")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            model: model, instructions: instructions, input: input, tools: tools, effort: effort))
        Log.info("Codex request model=\(model) bytes=\(request.httpBody?.count ?? 0) items=\(input.count)")
        let start = Date()
        let session = session
        let response = try await AsyncTimeout.run(seconds: 120, message: "The planner timed out.") {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte); if body.count >= 2048 { break } }
                throw Self.serviceError(status: status, body: body)
            }
            var events: [[String: Any]] = []
            for try await line in bytes.lines {
                guard let event = Self.event(fromLine: line) else { continue }
                events.append(event)
                if ["response.completed", "response.failed", "response.incomplete", "error"].contains(event["type"] as? String ?? "") { break }
            }
            return try Self.collect(events)
        }
        try Task.checkCancellation()
        Log.info("Timing codex_ms=\(Int(Date().timeIntervalSince(start) * 1000)) calls=\(response.functionCalls.count)")
        return response
    }

    nonisolated static func event(fromLine line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func collect(_ events: [[String: Any]]) throws -> CodexResponse {
        var items: [[String: Any]] = []
        var completed: [[String: Any]]?
        for event in events {
            switch event["type"] as? String {
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any] { items.append(item) }
            case "response.completed":
                completed = (event["response"] as? [String: Any])?["output"] as? [[String: Any]]
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
                let detail = (error?["message"] as? String) ?? (event["message"] as? String)
                Log.info("Codex stream error type=\(event["type"] as? String ?? "") detail=\(String((detail ?? "").prefix(300)))")
                throw CodexServiceError(status: 502, message: "ChatGPT could not complete this step. No further input was sent.")
            default: break
            }
        }
        if let completed, !completed.isEmpty { return CodexResponse(output: completed) }
        guard completed != nil || !items.isEmpty else {
            throw CodexServiceError(status: 502, message: "ChatGPT disconnected before completing its response.")
        }
        return CodexResponse(output: items)
    }

    nonisolated static func serviceError(status: Int, body: Data) -> CodexServiceError {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["detail"] as? String) ?? ""
        Log.info("Codex error HTTP \(status) detail=\(String(detail.prefix(300)).replacingOccurrences(of: "\n", with: " "))")
        let messages = [401: "ChatGPT session expired. Sign in again in Third Hand setup.",
                        403: "Your ChatGPT account cannot use this model or endpoint.",
                        429: "ChatGPT usage limit reached. Wait for your allowance to reset."]
        let fallback = detail.isEmpty
            ? "ChatGPT returned \(status). The Codex endpoint or model access may have changed."
            : "ChatGPT returned \(status): \(detail.prefix(200))"
        return CodexServiceError(status: status, message: messages[status] ?? fallback)
    }
}
