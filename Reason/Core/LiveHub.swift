import Foundation

/// One Server-Sent Events frame.
struct SSEFrame {
    var event: String
    var data: String
    var id: String?
    var json: [String: Any]? {
        guard let d = data.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

/// Reads a `text/event-stream` and reconnects with backoff, resuming from the last `id`.
final class SSEStream {
    private let makeRequest: (String?) -> URLRequest
    private let onFrame: @MainActor (SSEFrame) -> Void
    private var task: Task<Void, Never>?
    private var lastEventId: String?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120        // server pulses every 45s
        c.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: c)
    }()

    init(makeRequest: @escaping (String?) -> URLRequest, onFrame: @escaping @MainActor (SSEFrame) -> Void) {
        self.makeRequest = makeRequest
        self.onFrame = onFrame
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.run()
                    backoff = 1
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func run() async throws {
        let (bytes, resp) = try await session.bytes(for: makeRequest(lastEventId))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var event = "message"
        var data: [String] = []
        // `lines` skips blank separators, so a frame is flushed when its `data:` arrives
        // (Reason sends one data line per frame) and ids are tracked as they come.
        for try await line in bytes.lines {
            if line.hasPrefix(":") { continue }
            let (field, value) = Self.split(line)
            switch field {
            case "event":
                event = value
            case "data":
                data.append(value)
                let frame = SSEFrame(event: event, data: data.joined(separator: "\n"), id: lastEventId)
                data.removeAll()
                let name = event
                event = "message"
                if name == "reconnect" { await onFrame(frame); return }
                await onFrame(frame)
            case "id":
                lastEventId = value
            default:
                break
            }
        }
    }

    private static func split(_ line: String) -> (String, String) {
        guard let i = line.firstIndex(of: ":") else { return (line, "") }
        var v = line[line.index(after: i)...]
        if v.first == " " { v = v.dropFirst() }
        return (String(line[..<i]), String(v))
    }
}

/// Workspace-wide live signals from `/events` and `/changes`, fanned out with NotificationCenter.
@MainActor
final class LiveHub {
    static let shared = LiveHub()

    struct SessionEvent {
        let type: String          // message.created | turn.started | turn.finished | input_request.*
        let sessionId: String
        let payload: [String: Any]
    }

    static let sessionEvent = Notification.Name("reason.live.session")
    static let viewsChanged = Notification.Name("reason.live.changed")   // userInfo["topics"]: [String]
    static let resumed = Notification.Name("reason.live.resumed")        // app came back to the foreground

    /// Sessions with a turn executing right now.
    private(set) var running: Set<String> = []

    private var events: SSEStream?
    private var changes: SSEStream?
    private var revisions: [String: String] = [:]

    func start(api: ReasonAPI) {
        stop()
        events = SSEStream(makeRequest: { api.streamRequest("events", lastEventId: $0) }) { [weak self] f in
            self?.handleEvent(f)
        }
        changes = SSEStream(makeRequest: { _ in api.streamRequest("changes") }) { [weak self] f in
            self?.handleChange(f)
        }
        events?.start()
        changes?.start()
    }

    func stop() {
        events?.stop(); changes?.stop()
        events = nil; changes = nil
    }

    private func handleEvent(_ f: SSEFrame) {
        guard f.event != "hello", let obj = f.json else { return }
        let data = obj["data"] as? [String: Any] ?? [:]
        let type = (obj["type"] as? String) ?? f.event
        guard let sid = (obj["session_id"] as? String) ?? (data["session_id"] as? String)
                ?? ((obj["session"] as? [String: Any])?["id"] as? String) else { return }
        switch type {
        case "turn.started": running.insert(sid)
        case "turn.finished": running.remove(sid)
        default: break
        }
        NotificationCenter.default.post(name: Self.sessionEvent, object: SessionEvent(type: type, sessionId: sid, payload: obj))
    }

    private func handleChange(_ f: SSEFrame) {
        guard let obj = f.json, let revs = obj["revisions"] as? [String: String] else { return }
        let moved = revs.filter { revisions[$0.key] != nil && revisions[$0.key] != $0.value }.map(\.key)
        revisions.merge(revs) { _, new in new }
        if !moved.isEmpty {
            NotificationCenter.default.post(name: Self.viewsChanged, object: nil, userInfo: ["topics": moved])
        }
    }
}
