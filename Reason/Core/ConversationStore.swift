import Foundation

/// Holds one conversation (a Reason's, or a single Session's) and keeps it fresh
/// by cursor-polling. Shared between the list (for previews) and the chat screen.
@MainActor
final class ConversationStore {
    enum Source: Hashable {
        case reason(String)
        case session(String)
    }

    let source: Source
    private let api: ReasonAPI
    private(set) var items: [ConversationItem] = []
    private(set) var endCursor: String?
    private(set) var loaded = false
    private var loading: Task<Void, Error>?

    private struct Snapshot: Codable { var items: [ConversationItem]; var endCursor: String? }
    private var cacheKey: String {
        switch source { case .reason(let id): return "conv-r-" + id; case .session(let id): return "conv-s-" + id }
    }

    init(source: Source, api: ReasonAPI) {
        self.source = source
        self.api = api
        // Last-known conversation: shown instantly, then topped up from its cursor.
        if let snap = DiskCache.load(cacheKey, as: Snapshot.self), !snap.items.isEmpty {
            items = snap.items
            endCursor = snap.endCursor
            loaded = true
        }
    }

    private func persist() { DiskCache.save(cacheKey, Snapshot(items: items, endCursor: endCursor)) }

    /// Items worth drawing (empty placeholder replies are skipped).
    var visibleItems: [ConversationItem] { items.filter { !$0.text.isEmpty || $0.isFailedReply } }
    var lastVisible: ConversationItem? { visibleItems.last }

    private func page(after: String?) async throws -> ItemsPage<ConversationItem> {
        switch source {
        case .reason(let id): return try await api.reasonMessages(id, after: after)
        case .session(let id): return try await api.sessionConversation(id, after: after)
        }
    }

    /// Loads every page once. Concurrent callers share the same load.
    func loadAll() async throws {
        if loaded { return }
        if let loading { return try await loading.value }
        let t = Task { @MainActor in
            var cursor: String? = nil
            var all: [ConversationItem] = []
            while true {
                let p = try await page(after: cursor)
                all.append(contentsOf: p.items)
                if let c = p.endCursor { cursor = c }
                if p.hasNextPage != true || p.items.isEmpty { break }
            }
            items = all
            endCursor = cursor
            loaded = true
            persist()
        }
        loading = t
        defer { loading = nil }
        try await t.value
    }

    /// Fetches anything after the cursor. Returns (inserted ids, updated ids).
    @discardableResult
    func poll() async throws -> (inserted: [String], updated: [String]) {
        guard loaded else { try await loadAll(); return (items.map(\.id), []) }
        var inserted: [String] = []
        var updated: [String] = []
        var cursor = endCursor
        while true {
            let p = try await page(after: cursor)
            for item in p.items {
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    if items[i] != item { items[i] = item; updated.append(item.id) }
                } else {
                    items.append(item); inserted.append(item.id)
                }
            }
            if let c = p.endCursor { cursor = c }
            if p.hasNextPage != true || p.items.isEmpty { break }
        }
        endCursor = cursor
        if !inserted.isEmpty || !updated.isEmpty { persist() }
        return (inserted, updated)
    }
}

/// App-wide state: the API client and per-conversation stores.
@MainActor
final class AppState {
    static var shared: AppState!

    let api: ReasonAPI
    var me: SelfInfo?
    var models: [ModelsResponse.Model] = []
    var groups: [ModelsResponse.Group] = []
    private var stores: [ConversationStore.Source: ConversationStore] = [:]

    var reasons: [Reason] = []

    init(api: ReasonAPI) {
        self.api = api
        if let me = DiskCache.load("self", as: SelfInfo.self) {
            self.me = me
            api.adopt(orgId: me.orgId)
        }
        reasons = DiskCache.load("reasons", as: [Reason].self) ?? []
    }

    /// Resolves the org (once) before the first request that needs it.
    func ensureConnected() async throws {
        if api.isConnected && me != nil { return }
        let me = try await api.connect()
        self.me = me
        DiskCache.save("self", me)
    }

    func remember(reasons: [Reason]) {
        self.reasons = reasons
        DiskCache.save("reasons", reasons)
    }

    private var activities: [String: SessionActivity] = [:]

    /// Tool activity per Session, shared by every screen that shows it.
    func activity(_ sessionId: String) -> SessionActivity {
        if let a = activities[sessionId] { return a }
        let a = SessionActivity(sessionId: sessionId, api: api)
        activities[sessionId] = a
        return a
    }

    func store(_ source: ConversationStore.Source) -> ConversationStore {
        if let s = stores[source] { return s }
        let s = ConversationStore(source: source, api: api)
        stores[source] = s
        return s
    }

    // Model selection persists per device.
    var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: "model") }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    var selectedEffort: String? {
        get { UserDefaults.standard.string(forKey: "effort") }
        set { UserDefaults.standard.set(newValue, forKey: "effort") }
    }
    var fastMode: Bool {
        get { UserDefaults.standard.bool(forKey: "fast") }
        set { UserDefaults.standard.set(newValue, forKey: "fast") }
    }

    /// Choice for a brand-new conversation: whatever was picked last anywhere.
    var defaultChoice: ModelChoice.Value {
        get { ModelChoice.Value(model: selectedModel, source: selectedSource, effort: selectedEffort, fast: fastMode) }
        set { selectedModel = newValue.model; selectedSource = newValue.source; selectedEffort = newValue.effort; fastMode = newValue.fast }
    }
    /// The connected account a byok model runs on (`model_source_id`).
    var selectedSource: String? {
        get { UserDefaults.standard.string(forKey: "modelSource") }
        set { UserDefaults.standard.set(newValue, forKey: "modelSource") }
    }
    var currentModel: ModelsResponse.Model? { models.first { $0.id == selectedModel } }

    /// Display name for a connected account, numbering unnamed "Slot …" ones like the desktop app.
    func accountName(_ a: ModelsResponse.Account, in g: ModelsResponse.Group) -> String {
        if let l = a.accountLabel, !l.hasPrefix("Slot ") { return l }
        let idx = (g.accounts ?? []).firstIndex(of: a) ?? 0
        return "Account \(idx + 1)"
    }

    func select(model: String?, source: String?) {
        selectedModel = model
        selectedSource = source
        if let e = selectedEffort, let efforts = currentModel?.reasoningEfforts, !efforts.contains(e) {
            selectedEffort = efforts.contains("high") ? "high" : nil
        }
        NotificationCenter.default.post(name: .modelSelectionChanged, object: nil)
    }

    /// Loads the picker's model list once.
    func loadModels() async {
        guard models.isEmpty, let r = try? await api.models() else { return }
        models = r.models.filter { $0.hidden != true && $0.available != false }
        groups = r.groups ?? []
        NotificationCenter.default.post(name: .modelsChanged, object: nil)
    }
}

extension Notification.Name {
    static let modelsChanged = Notification.Name("reason.modelsChanged")
    static let modelSelectionChanged = Notification.Name("reason.modelSelectionChanged")
}

/// The model a chat will use for its next message. Each chat owns one; it starts from what the
/// conversation last ran on, so you don't have to pick the model again for every message.
@MainActor
final class ModelChoice {
    struct Value: Equatable {
        var model: String?
        var source: String?
        var effort: String?
        var fast = false
    }

    private(set) var value = Value()
    var onChange: (() -> Void)?

    var model: String? { value.model }
    var source: String? { value.source }
    var effort: String? { value.effort }
    var fast: Bool { value.fast }

    func currentModel(_ app: AppState) -> ModelsResponse.Model? { app.models.first { $0.id == value.model } }

    func reset(to v: Value) { value = v; onChange?() }

    func set(model: String?, source: String?, app: AppState) {
        value.model = model
        value.source = source
        if let e = value.effort, let efforts = currentModel(app)?.reasoningEfforts, !efforts.contains(e) {
            value.effort = efforts.contains("high") ? "high" : nil
        }
        onChange?()
    }

    func setEffort(_ e: String?) { value.effort = e; onChange?() }
    func toggleFast() { value.fast.toggle(); onChange?() }

    /// What the last reply in a conversation ran on.
    static func from(run: RunInfo?) -> Value? {
        guard let run, let m = run.model else { return nil }
        let src = (run.modelSourceId == nil || run.modelSourceId == "ara") ? nil : run.modelSourceId
        return Value(model: m, source: m.hasPrefix("byok:") ? src : nil, effort: run.reasoningEffort, fast: run.speed == "fast")
    }
}
