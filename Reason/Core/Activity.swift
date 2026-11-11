import Foundation

/// One tool call (or a short note the agent wrote between calls) inside a turn.
struct ActivityStep: Codable, Hashable {
    enum Kind: String, Codable { case command, read, edit, search, web, session, code, tool, note }
    let id: String
    var kind: Kind
    var icon: String
    var title: String          // "Ran", "Read", "Edited", "Messaged session"…
    var detail: String?        // the command, path, URL… on one line
    var input: String?         // full command / code, for the detail sheet
    var output: String?        // tool output, trimmed
    var done: Bool
    var failed: Bool
    var durationMs: Int?
}

/// An image the agent showed the user (`app_show`): a Session attachment, fetched by id.
struct ActivityShot: Codable, Hashable {
    let id: String              // the Session attachment id
    var caption: String?
    var width: Double?
    var height: Double?
    var aspect: CGFloat { CGFloat((height ?? 0) > 0 && (width ?? 0) > 0 ? height! / width! : 0.6) }
}

/// Everything one turn did: an Attempt in the event log (seq >> 32).
struct ActivityTurn: Codable, Hashable {
    let attempt: Int64
    var start: Date
    var end: Date
    var steps: [ActivityStep]
    var finalText: String?     // the last thing it said, which is the reply
    var shots: [ActivityShot]? // screenshots it showed you

    var tools: [ActivityStep] { steps.filter { $0.kind != .note } }

    /// "Ran 12 commands, read 4 files" — the turn at a glance.
    var summary: String {
        let t = tools
        func n(_ k: ActivityStep.Kind) -> Int { t.filter { $0.kind == k }.count }
        func plural(_ c: Int, _ one: String, _ many: String) -> String { "\(c) \(c == 1 ? one : many)" }
        var bits: [String] = []
        if n(.command) > 0 { bits.append("ran " + plural(n(.command), "command", "commands")) }
        if n(.read) > 0 { bits.append("read " + plural(n(.read), "file", "files")) }
        if n(.edit) > 0 { bits.append("edited " + plural(n(.edit), "file", "files")) }
        if n(.search) > 0 { bits.append(plural(n(.search), "search", "searches")) }
        if n(.web) > 0 { bits.append(plural(n(.web), "browser step", "browser steps")) }
        if n(.session) > 0 { bits.append(plural(n(.session), "session message", "session messages")) }
        let other = n(.code) + n(.tool)
        if other > 0 { bits.append("used " + plural(other, "tool", "tools")) }
        guard var s = bits.first else { return "Thought it through" }
        // Two parts read whole on a phone; the rest is one tap away.
        if bits.count > 1 { s += " and " + bits[1] }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    var failedCount: Int { tools.filter(\.failed).count }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var running: Bool { tools.contains { !$0.done } }

    static func durationText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(max(1, s))s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// A Session's tool activity, turn by turn, from its event log (`view=conversation`). Cached on disk
/// so a reopened chat shows it on the first frame; then only newer events are fetched.
@MainActor
final class SessionActivity {
    let sessionId: String
    private let api: ReasonAPI
    private var events: [String: SessionEventsPage.Event] = [:]
    private var cursor: Int64 = -1
    private(set) var turns: [ActivityTurn] = []
    private(set) var loaded = false

    private struct Snapshot: Codable { let cursor: Int64; let turns: [ActivityTurn] }

    init(sessionId: String, api: ReasonAPI) {
        self.sessionId = sessionId
        self.api = api
        if let s = DiskCache.load("act-" + sessionId, as: Snapshot.self) { turns = s.turns }
    }

    /// The whole log. Typical Sessions fit in one page; long ones take a few.
    func loadAll() async throws {
        var c: Int64 = -1
        var all: [String: SessionEventsPage.Event] = [:]
        for _ in 0..<25 {
            let p = try await api.events(sessionId, afterSeq: c, waitMs: 0, limit: 1000)
            for e in p.items { if (all[e.id]?.seq ?? -1) < e.seq { all[e.id] = e } }
            guard p.items.count >= 1000, let n = p.nextSeq, n > c else { c = p.nextSeq ?? c; break }
            c = n
        }
        events = all
        cursor = c
        loaded = true
        rebuild()
    }

    /// Waits up to `waitMs` for new events. Returns whether anything changed.
    @discardableResult
    func poll(waitMs: Int) async throws -> Bool {
        guard loaded else { try await loadAll(); return true }
        let p = try await api.events(sessionId, afterSeq: cursor, waitMs: waitMs, limit: 1000)
        if let n = p.nextSeq { cursor = max(cursor, n) }
        guard !p.items.isEmpty else { return false }
        for e in p.items { if (events[e.id]?.seq ?? -1) < e.seq { events[e.id] = e } }
        rebuild()
        return true
    }

    private func rebuild() {
        let byAttempt = Dictionary(grouping: events.values) { $0.seq >> 32 }
        turns = byAttempt.keys.sorted().compactMap { a in Self.turn(attempt: a, events: byAttempt[a]!) }
        // Outputs are capped, so the cache stays small even for long Sessions.
        DiskCache.save("act-" + sessionId, Snapshot(cursor: cursor, turns: turns))
    }

    private static func turn(attempt: Int64, events: [SessionEventsPage.Event]) -> ActivityTurn? {
        let ordered = events.sorted { ($0.position ?? $0.seq, $0.seq) < ($1.position ?? $1.seq, $1.seq) }
        let dates = ordered.compactMap { $0.createdAt.flatMap(ISODate.parse) }
        guard let start = dates.min(), let end = dates.max() else { return nil }
        var results: [String: SessionEventsPage.Event] = [:]
        for e in ordered where e.type == "tool_result" {
            guard let id = e.data?.toolUseId else { continue }
            // Prefer the finished result over partial snapshots.
            if let old = results[id], old.data?.isPartial != true, e.data?.isPartial == true { continue }
            results[id] = e
        }
        var steps: [ActivityStep] = []
        var lastText: String?
        // `app_show` results carry {"app_cards":[{id, kind:"image", caption, dimensions}]}.
        var shots: [ActivityShot] = []
        for e in ordered where e.type == "tool_result" && e.data?.isPartial != true {
            guard let d = e.data?.details?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cards = obj["app_cards"] as? [[String: Any]] else { continue }
            for c in cards where (c["kind"] as? String) == "image" {
                guard let id = c["id"] as? String, !shots.contains(where: { $0.id == id }) else { continue }
                let dims = c["dimensions"] as? [String: Any]
                shots.append(ActivityShot(id: id, caption: c["caption"] as? String,
                                          width: (dims?["width"] as? NSNumber)?.doubleValue, height: (dims?["height"] as? NSNumber)?.doubleValue))
            }
        }
        for e in ordered {
            switch e.type {
            case "tool_use":
                let r = e.data?.toolUseId.flatMap { results[$0] }
                let finished = r != nil && r?.data?.isPartial != true
                var s = step(tool: e.data?.tool ?? e.text ?? "tool", input: e.data?.input, id: e.id)
                s.done = finished
                s.failed = r?.data?.isError == true || r?.text == "failed"
                s.output = r?.data?.content.map(cleanOutput)
                s.durationMs = r?.data?.durationMs
                steps.append(s)
            case "assistant":
                guard let t = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                lastText = t
                steps.append(ActivityStep(id: e.id, kind: .note, icon: "text.bubble", title: "", detail: t, input: nil, output: nil,
                                          done: true, failed: false, durationMs: nil))
            default: break
            }
        }
        // The last thing it said is the reply itself; it already has its own bubble.
        if let i = steps.lastIndex(where: { $0.kind == .note }), steps[(i + 1)...].allSatisfy({ $0.kind == .note }) {
            steps.remove(at: i)
        }
        return ActivityTurn(attempt: attempt, start: start, end: end, steps: steps, finalText: lastText, shots: shots.isEmpty ? nil : shots)
    }

    // MARK: Describing tools

    static func step(tool: String, input: String?, id: String) -> ActivityStep {
        let obj = input.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        func str(_ k: String) -> String? { (obj?[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func oneLine(_ s: String?) -> String? {
            s.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }.map { String($0.prefix(200)) }
        }
        var s = ActivityStep(id: id, kind: .tool, icon: "wrench.and.screwdriver", title: tool.replacingOccurrences(of: "_", with: " ").capitalized,
                             detail: nil, input: input, output: nil, done: false, failed: false, durationMs: nil)
        switch tool.lowercased() {
        case "bash", "exec", "shell", "exec_command":
            s.kind = .command; s.icon = "terminal"; s.title = "Ran"
            s.input = str("command") ?? str("cmd") ?? input
            s.detail = oneLine(s.input)
        case "read", "read_file", "view":
            s.kind = .read; s.icon = "doc.text"; s.title = "Read"
            s.detail = str("path") ?? str("file_path"); s.input = s.detail
        case "write", "edit", "apply_patch", "str_replace", "multi_edit":
            s.kind = .edit; s.icon = "pencil"; s.title = tool.lowercased() == "write" ? "Wrote" : "Edited"
            s.detail = str("path") ?? str("file_path")
            s.input = str("content") ?? str("patch") ?? str("new_string") ?? input
        case let t where t.contains("grep") || t.contains("search") || t == "glob":
            s.kind = .search; s.icon = "magnifyingglass"; s.title = "Searched"
            s.detail = oneLine(str("pattern") ?? str("query"))
        case let t where t.contains("browser") || t.contains("web") || t == "fetch":
            s.kind = .web; s.icon = "globe"; s.title = "Browser"
            let args = obj?["arguments"] as? [String: Any]
            let action = (str("tool") ?? "").replacingOccurrences(of: "_", with: " ")
            if !action.isEmpty { s.title = action.prefix(1).uppercased() + action.dropFirst() }
            s.detail = (args?["url"] as? String) ?? str("url") ?? str("query")
        case "codemode":
            let code = str("code") ?? input ?? ""
            s.input = code
            if let (title, detail) = sessionCall(code) {
                s.kind = .session; s.icon = "arrow.triangle.branch"; s.title = title; s.detail = detail
            } else {
                s.kind = .code; s.icon = "curlybraces"; s.title = "Ran code"
                // `tools.secrets_list({})` → "secrets list"
                if let r = code.range(of: #"tools\.([a-z_]+)"#, options: .regularExpression) {
                    s.title = "Used"
                    s.detail = String(code[r]).replacingOccurrences(of: "tools.", with: "").replacingOccurrences(of: "_", with: " ")
                } else {
                    s.detail = oneLine(code.split(separator: "\n").first.map(String.init))
                }
            }
        default:
            s.detail = oneLine(str("command") ?? str("path") ?? str("query") ?? str("url") ?? str("title") ?? str("prompt"))
        }
        return s
    }

    /// The Reason drives child Sessions from code: `tools.sessions_create({title: …})`, `tools.sessions_send(…)`.
    static func sessionCall(_ code: String) -> (String, String?)? {
        let title: String
        if code.contains("sessions_create") { title = "Started session" }
        else if code.contains("sessions_send") || code.contains("sessions_message") || code.contains("sessions_follow") { title = "Messaged session" }
        else if code.contains("sessions_cancel") { title = "Stopped session" }
        else { return nil }
        let detail = ["title", "prompt", "message"].lazy.compactMap { key -> String? in
            guard let r = code.range(of: key + #"\s*:\s*["'`]([^"'`]{1,90})"#, options: .regularExpression) else { return nil }
            return String(code[r]).replacingOccurrences(of: key + #"\s*:\s*["'`]"#, with: "", options: .regularExpression)
        }.first
        return (title, detail)
    }

    /// Drops the "untrusted data" preamble Reason wraps around workspace output, and caps the size.
    static func cleanOutput(_ s: String) -> String {
        var out = s
        if let r = out.range(of: "[END NOTICE]") { out = String(out[r.upperBound...]) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 8000
        if out.count > cap { out = String(out.prefix(cap)) + "\n…" }
        return out
    }
}
