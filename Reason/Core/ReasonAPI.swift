import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Thin async client over https://api.reasonmachines.com/v3.
final class ReasonAPI {
    static let base = URL(string: "https://api.reasonmachines.com/v3")!

    let apiKey: String
    private(set) var orgId: String = ""
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40   // long polls wait up to 20s server-side
        cfg.httpAdditionalHeaders = ["X-Reason-Agent": "reason-ios"]
        session = URLSession(configuration: cfg)
    }

    // MARK: Core

    private func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Any? = nil,
                         raw: Data? = nil, contentType: String? = nil) async throws -> Data {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let q = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !q.isEmpty { comps.queryItems = q }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let raw {
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = raw
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: Self.errorMessage(data) ?? "Request failed (\(status))")
        }
        return data
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let d = obj["detail"] as? String { return d }
        if let e = obj["error"] as? String { return e }
        return nil
    }

    /// POST a JSON body that carries files: streamed to disk, then uploaded from the file.
    private func upload(_ path: String, fields: [String: Any], files: [LocalFile]) async throws -> Data {
        let bodyURL = try await Task.detached(priority: .userInitiated) { try MessageBodyWriter.write(fields: fields, files: files) }.value
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, fromFile: bodyURL)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: Self.errorMessage(data) ?? (status == 413 ? "Attachments are too large." : "Upload failed (\(status))"))
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try decoder.decode(T.self, from: try await request("GET", path, query: query))
    }

    private func post<T: Decodable>(_ path: String, body: Any) async throws -> T {
        try decoder.decode(T.self, from: try await request("POST", path, body: body))
    }

    private var org: String { "organizations/\(orgId)" }

    // MARK: Endpoints

    /// Use a remembered org so requests can start before /self answers.
    func adopt(orgId: String) { if self.orgId.isEmpty { self.orgId = orgId } }
    var isConnected: Bool { !orgId.isEmpty }

    @discardableResult
    func connect() async throws -> SelfInfo {
        let me: SelfInfo = try await get("self")
        orgId = me.orgId
        return me
    }

    func reasons() async throws -> [Reason] {
        let page: ItemsPage<Reason> = try await get("\(org)/reasons")
        return page.items
    }

    func createReason(name: String, instructions: String? = nil, appearance: Appearance? = nil) async throws -> Reason {
        var body: [String: Any] = ["name": name]
        if let instructions { body["instructions"] = instructions }
        if let a = appearance {
            body["appearance"] = ["color": a.color ?? "blue", "eyes": a.eyes ?? "pills", "glasses": "none", "accessory": "none"]
        }
        return try await post("\(org)/reasons", body: body)
    }

    func reasonMessages(_ reasonId: String, after: String?) async throws -> ItemsPage<ConversationItem> {
        try await get("\(org)/reasons/\(reasonId)/messages", query: ["first": "200", "after": after])
    }

    func sendReasonMessage(_ reasonId: String, text: String, clientId: String, model: String?, source: String? = nil,
                           effort: String?, speed: String?, files: [LocalFile] = []) async throws -> SendMessageResponse {
        var body: [String: Any] = ["message": text, "client_message_id": clientId]
        if let model { body["model"] = model }
        if let source, model != nil { body["model_source_id"] = source }
        if let effort { body["reasoning_effort"] = effort }
        if let speed { body["speed"] = speed }
        if !files.isEmpty {
            return try decoder.decode(SendMessageResponse.self, from: try await upload("\(org)/reasons/\(reasonId)/messages", fields: body, files: files))
        }
        return try await post("\(org)/reasons/\(reasonId)/messages", body: body)
    }

    func sessionConversation(_ sessionId: String, after: String?) async throws -> ItemsPage<ConversationItem> {
        try await get("\(org)/sessions/\(sessionId)/conversation", query: ["first": "200", "after": after])
    }

    func sendSessionMessage(_ sessionId: String, text: String) async throws {
        _ = try await request("POST", "\(org)/sessions/\(sessionId)/messages", body: ["message": text])
    }

    func sessions(reasonId: String?, first: Int = 30) async throws -> [SessionSummary] {
        let page: ItemsPage<SessionSummary> = try await get("\(org)/sessions", query: [
            "reason_id": reasonId, "first": String(first),
            "fields": "title,status,outcome,updated_at,created_at,repo,pr_url,cost_usd,model,reasoning_effort,created_by_session_id",
        ])
        return page.items
    }

    func session(_ sessionId: String) async throws -> SessionSummary {
        try await get("\(org)/sessions/\(sessionId)")
    }

    func events(_ sessionId: String, afterSeq: Int64, waitMs: Int, limit: Int = 1000) async throws -> SessionEventsPage {
        try await get("\(org)/sessions/\(sessionId)/events", query: [
            "after_seq": String(afterSeq), "view": "conversation",
            "limit": String(limit), "wait_ms": waitMs > 0 ? String(waitMs) : nil,
        ])
    }

    /// Cursor just before the newest Attempt's events. `seq` = attempt × 2^32 + counter, and every
    /// follow-up starts a new Attempt, so a few `limit=1` probes find the tail without paging history.
    func latestAttemptCursor(_ sessionId: String) async throws -> Int64 {
        func exists(_ attempt: Int64) async throws -> Bool {
            let p = try await events(sessionId, afterSeq: (attempt << 32) - 1, waitMs: 0, limit: 1)
            return !p.items.isEmpty
        }
        var hi: Int64 = 1
        while try await exists(hi) { hi *= 2; if hi > 1 << 20 { break } }
        var lo = hi / 2          // exists(lo) is true (or lo == 0)
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if try await exists(mid) { lo = mid } else { hi = mid }
        }
        return (lo << 32) - 1
    }

    func sessionAttachments(_ sessionId: String) async throws -> [SessionAttachment] {
        let page: ItemsPage<SessionAttachment> = try await get("\(org)/sessions/\(sessionId)/attachments")
        return page.items
    }

    /// Server-Sent Events request for `/events` or `/changes`.
    func streamRequest(_ path: String, query: [String: String?] = [:], lastEventId: String? = nil) -> URLRequest {
        var comps = URLComponents(url: Self.base.appendingPathComponent("\(org)/\(path)"), resolvingAgainstBaseURL: false)!
        let q = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !q.isEmpty { comps.queryItems = q }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("reason-ios", forHTTPHeaderField: "X-Reason-Agent")
        if let lastEventId { req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID") }
        req.timeoutInterval = 120
        return req
    }

    func cancel(_ sessionId: String) async throws {
        _ = try await request("POST", "\(org)/sessions/\(sessionId)/cancel", body: ["mode": "graceful"])
    }

    /// Speech → text, as the app's dictation does. `language: "multi"` auto-detects (English/Spanish/…).
    func transcribe(audio: Data, contentType: String, language: String = "multi") async throws -> Transcript {
        let data = try await request("POST", "\(org)/transcribe", query: ["language": language], raw: audio, contentType: contentType)
        return try decoder.decode(Transcript.self, from: data)
    }

    /// Untyped GET for read-only dashboards (profile): `org` paths are relative to the workspace.
    func json(_ path: String, org scoped: Bool = true, query: [String: String?] = [:]) async throws -> [String: Any] {
        let data = try await request("GET", scoped ? "\(org)/\(path)" : path, query: query)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Input requests

    func inputRequests(_ sessionId: String) async throws -> [InputRequest] {
        let page: ItemsPage<InputRequest> = try await get("\(org)/sessions/\(sessionId)/input-requests")
        return page.items
    }

    /// One answer per question: chosen option labels and/or free text.
    func answer(_ sessionId: String, request id: String, answers: [(selected: [String], text: String?)]) async throws {
        let body: [String: Any] = ["answers": answers.map { a -> [String: Any] in
            var o: [String: Any] = [:]
            if !a.selected.isEmpty { o["selected"] = a.selected }
            if let t = a.text, !t.isEmpty { o["text"] = t }
            return o
        }]
        _ = try await request("POST", "\(org)/sessions/\(sessionId)/input-requests/\(id)/answer", body: body)
    }

    func resolve(_ sessionId: String, request id: String, action: String, value: String? = nil) async throws {
        let body: [String: Any] = value.map { ["value": $0] } ?? [:]
        _ = try await request("POST", "\(org)/sessions/\(sessionId)/input-requests/\(id)/\(action)", body: body)
    }

    /// Workspace secret names (never values), with when each was last saved.
    struct SecretName: Decodable { let name: String; var createdAt: String?; var updatedAt: String? }
    func secretNames() async throws -> [SecretName] {
        let page: ItemsPage<SecretName> = try await get("\(org)/secrets")
        return page.items
    }

    func devices() async throws -> [DevicesPage.Device] {
        let page: DevicesPage = try await get("\(org)/devices", query: ["first": "20"])
        return page.devices
    }

    func models() async throws -> ModelsResponse {
        try await get("\(org)/agent-auth/models")
    }
}
