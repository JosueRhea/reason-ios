import Foundation

// MARK: - Account

struct SelfInfo: Codable {
    let orgId: String
    let organizationName: String?
    let serviceUserName: String?
}

// MARK: - Reasons

struct Appearance: Codable, Hashable {
    var color: String?
    var eyes: String?
    var shape: String?
}

struct Reason: Codable, Hashable {
    let id: String
    var name: String
    var main: Bool?
    var appearance: Appearance?
    var tagline: String?
    var sessionId: String?
    var updatedAt: String?
    var defaultModel: String?
    var defaultReasoningEffort: String?
}

struct ItemsPage<T: Decodable>: Decodable {
    let items: [T]
    var hasNextPage: Bool?
    var endCursor: String?
    var sessionId: String?
}

// MARK: - Conversation

struct Author: Codable, Hashable {
    var kind: String?
    var via: String?
    var title: String?
    var sessionId: String?
    var userId: String?
    var originAgent: String?
}

/// Attachment shapes aren't pinned down in the docs, so decode leniently.
struct Attachment: Codable, Hashable {
    var id: String?
    var filename: String?
    var name: String?
    var contentType: String?
    var url: String?
    var sizeBytes: Double?
    var width: Double?
    var height: Double?

    var isImage: Bool { contentType?.hasPrefix("image/") == true }
    var displayName: String { filename ?? name ?? "file" }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: AnyKey.self)
        id = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: AnyKey("id")) } ?? nil
        filename = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: AnyKey("filename")) } ?? nil
        name = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: AnyKey("name")) } ?? nil
        contentType = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: AnyKey("contentType")) } ?? nil
        url = c.flatMap { try? $0.decodeIfPresent(String.self, forKey: AnyKey("url")) } ?? nil
        sizeBytes = c.flatMap { try? $0.decodeIfPresent(Double.self, forKey: AnyKey("sizeBytes")) } ?? nil
        if let dims = c.flatMap({ try? $0.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("dimensions")) }) {
            width = try? dims.decodeIfPresent(Double.self, forKey: AnyKey("width"))
            height = try? dims.decodeIfPresent(Double.self, forKey: AnyKey("height"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(id, forKey: AnyKey("id"))
        try c.encodeIfPresent(filename, forKey: AnyKey("filename"))
        try c.encodeIfPresent(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(contentType, forKey: AnyKey("contentType"))
        try c.encodeIfPresent(url, forKey: AnyKey("url"))
        try c.encodeIfPresent(sizeBytes, forKey: AnyKey("sizeBytes"))
        if width != nil || height != nil {
            var d = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("dimensions"))
            try d.encodeIfPresent(width, forKey: AnyKey("width"))
            try d.encodeIfPresent(height, forKey: AnyKey("height"))
        }
    }
}

struct RunInfo: Codable, Hashable {
    var model: String?
    var modelSourceId: String?
    var reasoningEffort: String?
    var speed: String?
}

struct ConversationItem: Codable, Hashable {
    let id: String
    var run: RunInfo?
    var kind: String          // prompt | message | reply
    var role: String          // user | assistant
    var content: String?
    var status: String?
    var outcome: String?
    var attachments: [Attachment]?
    var author: Author?
    var createdAt: String?

    /// Sent by a person — directly, or through an API client acting for them (kind "agent" + user_id).
    var isMine: Bool { role == "user" && (author?.kind == nil || author?.kind == "person" || author?.userId != nil) }
    var text: String { (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var date: Date? { createdAt.flatMap(ISODate.parse) }
    var isFailedReply: Bool { kind == "reply" && (status == "error" || outcome == "failure") }
}

// MARK: - Sessions

struct Usage: Decodable, Hashable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
}

struct ContextInfo: Decodable, Hashable {
    var tokens: Int?
    var window: Int?
    var percent: Double?
}

struct SessionSummary: Decodable, Hashable {
    let sessionId: String
    var title: String?
    var model: String?
    var reasoningEffort: String?
    var costUsd: Double?
    var usage: Usage?
    var context: ContextInfo?
    var durationMs: Int?
    var createdBySessionId: String?
    var status: String?
    var outcome: String?
    var updatedAt: String?
    var createdAt: String?
    /// When the Session's current turn started.
    var startedAt: String?
    var repo: String?
    var prUrl: String?
    var resultSummary: String?
}

struct SessionEventsPage: Decodable {
    struct Session: Decodable { var status: String? }
    struct Event: Decodable {
        let id: String
        let seq: Int64
        var position: Int64?
        var type: String
        var text: String?
        var data: EventData?
        var createdAt: String?
    }
    /// The fixed data fields of the conversation view. `input` may be a JSON string or an object.
    struct EventData: Decodable {
        var tool: String?
        var toolUseId: String?
        var input: String?
        var isError: Bool?
        var isPartial: Bool?
        var durationMs: Int?
        var content: String?
        var details: String?    // JSON: e.g. {"app_cards":[…]} for images the agent showed the user

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            tool = try? c.decodeIfPresent(String.self, forKey: AnyKey("tool"))
            toolUseId = try? c.decodeIfPresent(String.self, forKey: AnyKey("toolUseId"))
            isError = try? c.decodeIfPresent(Bool.self, forKey: AnyKey("isError"))
            isPartial = try? c.decodeIfPresent(Bool.self, forKey: AnyKey("isPartial"))
            durationMs = try? c.decodeIfPresent(Int.self, forKey: AnyKey("durationMs"))
            if let s = try? c.decodeIfPresent(String.self, forKey: AnyKey("input")) {
                input = s
            } else if let obj = try? c.decodeIfPresent(JSONValue.self, forKey: AnyKey("input")) {
                input = obj.jsonString
            }
            details = (try? c.decodeIfPresent(JSONValue.self, forKey: AnyKey("details")))?.jsonString
            if let s = try? c.decodeIfPresent(String.self, forKey: AnyKey("content")) {
                content = s
            } else if let obj = try? c.decodeIfPresent(JSONValue.self, forKey: AnyKey("content")) {
                content = obj.jsonString
            }
        }
    }
    var session: Session?
    var items: [Event]
    var nextSeq: Int64?
}

// MARK: - Devices & models

struct DevicesPage: Decodable {
    struct Device: Decodable, Hashable {
        let id: String
        var name: String?
        var customName: String?
        var kind: String?
        var status: String?
        var os: String?
        var displayName: String { customName ?? name ?? "Computer" }
    }
    var devices: [Device]
}

struct ModelsResponse: Decodable {
    struct Model: Decodable, Hashable {
        let id: String
        var label: String?
        var detail: String?
        var reasoningEfforts: [String]?
        var hidden: Bool?
        var available: Bool?
        var provider: String?
        var contextWindow: Int?
        var imageInput: Bool?
        var accessTier: String?

        var sourceId: String?

        var supportsFast: Bool { provider == "openai-codex" || id.hasPrefix("byok:openai-codex:") }
        var displayName: String { label ?? id }
        var isReasonGateway: Bool { !id.hasPrefix("byok:") }
    }
    struct Account: Decodable, Hashable {
        let sourceId: String
        var accountLabel: String?
        var accountName: String?
        var accountEmail: String?
        var modelIds: [String]?
    }
    struct Group: Decodable {
        var providerId: String
        var label: String?
        var detail: String?
        var selectable: Bool?
        var accounts: [Account]?
        var models: [Model]?
    }
    var models: [Model]
    var groups: [Group]?
}

struct SessionAttachment: Decodable, Hashable {
    let id: String
    var name: String?
    var kind: String?
    var contentType: String?
    var url: String?
    var createdAt: String?
}

/// Minimal JSON tree for fields whose shape varies.
indirect enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues(\.any)
        case .array(let a): return a.map(\.any)
        case .null: return NSNull()
        }
    }

    var jsonString: String? {
        guard let d = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

struct Transcript: Decodable {
    var transcript: String
    var confidence: Double?
}

struct SendMessageResponse: Decodable {
    var sessionId: String?
}

// MARK: - Helpers

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum ISODate {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [String: Date] = [:]

    /// Memoized: the chat asks for every message's date several times per redraw, and ISO parsing is slow.
    static func parse(_ s: String) -> Date? {
        memoLock.lock(); defer { memoLock.unlock() }
        if let d = memo[s] { return d }
        guard let d = frac.date(from: s) ?? plain.date(from: s) else { return nil }
        if memo.count > 20_000 { memo.removeAll() }
        memo[s] = d
        return d
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d h:mm a"; return f
    }()
    private static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    /// "Fri, Nov 6 2:27 PM" — the separator style the desktop app uses.
    static func separator(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today " + timeFmt.string(from: d) : dayFmt.string(from: d)
    }

    /// Compact relative stamp for list rows: "8:25 PM", "Yesterday", "Nov 6".
    static func listStamp(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeFmt.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return shortDay.string(from: d)
    }

    /// "4d", "3h", "now" like the desktop sessions list.
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 30 { return "\(s / 86400)d" }
        return shortDay.string(from: d)
    }
}

// MARK: - Input requests (the agent waiting on you)

struct InputRequest: Decodable, Hashable {
    struct Option: Decodable, Hashable { var label: String; var description: String? }
    struct Question: Decodable, Hashable {
        var header: String?
        var question: String
        var multiSelect: Bool?
        var options: [Option]?
    }
    struct QuestionSet: Decodable, Hashable { var waitForAnswer: Bool?; var questions: [Question]? }
    struct SecretRequest: Decodable, Hashable {
        var name: String
        var label: String?
        var placeholder: String?
        var valuePrefix: String?
        var replace: Bool?
    }
    struct Hosts: Decodable, Hashable { var hosts: [String] }
    struct Rules: Decodable, Hashable { var changes: [String] }

    let id: String
    var type: String
    var status: String?
    var label: String?
    var reason: String?
    var createdAt: String?
    /// The Session that asked, when this is a copy shown in a Reason's conversation.
    var askedInSessionId: String?
    var question: QuestionSet?
    var secretRequest: SecretRequest?
    var networkHosts: Hosts?
    var permissionRules: Rules?
    var actions: [String]?
    var appUrl: String?

    var isPending: Bool { status == nil || status == "pending" }
    func can(_ action: String) -> Bool { actions?.contains(action) == true }
}
