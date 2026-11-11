import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Keeps the bottom of the conversation pinned while the view resizes
/// (keyboard, composer growth) — the iMessage behaviour.
final class ChatCollectionView: UICollectionView {
    /// While set, any growth (cells measuring their real height) keeps the view on the last message.
    var stickToBottom = false

    override var contentSize: CGSize {
        didSet {
            guard stickToBottom, contentSize.height != oldValue.height, !isTracking, !isDecelerating else { return }
            let maxY = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
            if contentOffset.y != maxY { contentOffset.y = maxY }
        }
    }

    override var bounds: CGRect {
        didSet {
            let dh = oldValue.height - bounds.height
            guard dh != 0, oldValue.height > 0, !isTracking else { return }
            let maxY = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
            let target = min(maxY, max(-adjustedContentInset.top, contentOffset.y + dh))
            if target != contentOffset.y { contentOffset.y = target }
        }
    }
}

final class ChatViewController: UIViewController, InputBarDelegate, UICollectionViewDelegate {
    enum Mode {
        case reason(Reason)
        case session(id: String, title: String)
    }

    private enum Row: Hashable {
        case stamp(String)
        case message(String)
        case request(String)
        case activity(String)
        case live
    }

    private struct Pending {
        let localId: String
        let text: String
        let date: Date
        var files: [LocalFile] = []
        var failed = false
        var serverId: String?
    }

    private let mode: Mode

    /// Whether this chat is the conversation a notification is about.
    func shows(reasonId: String?, sessionId: String?) -> Bool {
        switch mode {
        case .reason(let r): return r.id == reasonId
        case .session(let id, _): return id == sessionId
        }
    }
    private let app = AppState.shared!
    private let store: ConversationStore
    private var collectionView: ChatCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let inputBar = InputBar()
    private let titlePill = TitlePill()
    private let jumpButton = JumpButton()

    private var models: [String: MessageModel] = [:]
    private var stamps: [String: String] = [:]
    private var pending: [Pending] = []
    private var animateIn: Set<String> = []
    private var expanded: Set<String> = []
    /// Questions, secrets and approvals the agent is waiting on.
    private var pendingRequests: [InputRequest] = []
    /// Messages this Reason sent to its child Sessions ("Started" / "Messaged" rows).
    private struct ChildEvent { let id: String; let date: Date?; let verb: String; let title: String; let sessionId: String; let text: String }
    private var childEvents: [ChildEvent] = []
    private var childTitles: [String: String] = [:]
    private var childStatus: [String: String] = [:]   // running | finished | failed | stopped
    /// The model for the next message, and what the conversation last actually ran on.
    private let choice = ModelChoice()
    private var sessionChoice: ModelChoice.Value?
    private var conversationSession: SessionSummary?
    private var awaitingReply = false { didSet { if awaitingReply != oldValue { runningChanged() } } }
    private var lastSendDate: Date?
    private var suppressLive = false
    private var didInitialScroll = false
    private var pollTask: Task<Void, Never>?
    private var sessionId: String?
    private var observers: [NSObjectProtocol] = []

    // Live turn
    private var liveTask: Task<Void, Never>?
    private var liveSince = Date()
    private var liveEvents: [String: SessionEventsPage.Event] = [:]
    private var liveSteps: [LiveStep] = []
    private var liveText: String?
    private var liveRefreshScheduled = false

    // Tool activity: what each turn ran, above its reply
    private var activity: SessionActivity?
    private var activityModels: [String: ActivityModel] = [:]
    private var activityTask: Task<Void, Never>?
    /// Session view: the Session is mid-turn (its last turn shows live).
    private var sessionRunning = false
    /// Reason view: what each running child Session is doing right now, and the loops watching them.
    private var childNow: [String: ActivityStep] = [:]
    private var childWatchers: [String: Task<Void, Never>] = [:]

    /// Screenshots the agent showed (`app_show`) are Session attachments: id → signed URL and file name.
    private var shotFiles: [String: (url: URL, name: String)] = [:]
    private var shotsLoading = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .reason(let r):
            store = AppState.shared.store(.reason(r.id))
            sessionId = r.sessionId
        case .session(let id, _):
            store = AppState.shared.store(.session(id))
            sessionId = id
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var isReadOnly: Bool { if case .session = mode { return true }; return false }

    // MARK: Lifecycle

    override func viewDidLoad() {

        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never

        switch mode {
        case .reason(let r):
            titlePill.configure(name: r.name, appearance: r.appearance)
            titlePill.addTarget(self, action: #selector(showInfo), for: .touchUpInside)
            navigationItem.titleView = titlePill
            navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "sidebar.right"), style: .plain, target: self, action: #selector(showInfo))
        case .session(_, let title):
            titlePill.configure(name: title, appearance: nil, showsAvatar: false)
            navigationItem.titleView = titlePill
        }

        setUpCollectionView()
        setUpInputBar()
        setUpJumpButton()
        restoreChildEvents()
        render(animated: false)
        observeLive()

        Task { await initialLoad() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if renderWindow != nil {
            renderWindow = nil
            render(animated: false)
        }
        startFallbackPolling()
        if awaitingReply { startLive() }
        if sessionRunning { watchActivity() }
        syncChildWatchers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTask?.cancel(); pollTask = nil
        liveTask?.cancel(); liveTask = nil
        activityTask?.cancel(); activityTask = nil
        childWatchers.values.forEach { $0.cancel() }; childWatchers = [:]
        view.endEditing(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Lay the list out now (not on its own pass later), so the first frame is already at the bottom.
        if !didInitialScroll, store.loaded, !dataSource.snapshot().itemIdentifiers.isEmpty, collectionView.bounds.height > 0 {
            collectionView.layoutIfNeeded()
        }
        if !didInitialScroll, store.loaded, collectionView.contentSize.height > 0 {
            didInitialScroll = true
            pinToLastItem()
            // Long replies above the fold measure a beat later; stay on the last message meanwhile.
            collectionView.stickToBottom = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.collectionView.stickToBottom = false }
        }
    }

    private func setUpCollectionView() {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 16, trailing: 0)
        let layout = UICollectionViewCompositionalLayout(section: section)

        collectionView = ChatCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuse)
        collectionView.register(StampCell.self, forCellWithReuseIdentifier: StampCell.reuse)
        collectionView.register(LiveCell.self, forCellWithReuseIdentifier: LiveCell.reuse)
        collectionView.register(ReportCell.self, forCellWithReuseIdentifier: ReportCell.reuse)
        collectionView.register(NoticeCell.self, forCellWithReuseIdentifier: NoticeCell.reuse)
        collectionView.register(AgentNoteCell.self, forCellWithReuseIdentifier: AgentNoteCell.reuse)
        collectionView.register(ChildEventCell.self, forCellWithReuseIdentifier: ChildEventCell.reuse)
        collectionView.register(RequestCell.self, forCellWithReuseIdentifier: RequestCell.reuse)
        collectionView.register(ActivityCell.self, forCellWithReuseIdentifier: ActivityCell.reuse)
        if let sid = sessionId { activity = app.activity(sid) }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, ip, row in
            guard let self else { return nil }
            switch row {
            case .stamp(let id):
                let c = cv.dequeueReusableCell(withReuseIdentifier: StampCell.reuse, for: ip) as! StampCell
                c.label.text = self.stamps[id]
                return c
            case .message(let id):
                guard let m = self.models[id] else { return cv.dequeueReusableCell(withReuseIdentifier: StampCell.reuse, for: ip) }
                switch m.style {
                case .report(let title, _, let sid):
                    let c = cv.dequeueReusableCell(withReuseIdentifier: ReportCell.reuse, for: ip) as! ReportCell
                    c.configure(m)
                    c.onOpenSession = { [weak self] in if let sid { self?.openSession(sid, title: title) } }
                    c.onToggle = { [weak self] in self?.toggle(id) }
                    c.onImageTap = { [weak self] v, ref in self?.openImage(ref, from: v) }
                    c.chips.onTap = { [weak self] chip in self?.open(chip) }
                    return c
                case .notice:
                    let c = cv.dequeueReusableCell(withReuseIdentifier: NoticeCell.reuse, for: ip) as! NoticeCell
                    c.configure(m)
                    return c
                case .childEvent(_, let title, let sid, _):
                    let c = cv.dequeueReusableCell(withReuseIdentifier: ChildEventCell.reuse, for: ip) as! ChildEventCell
                    var appearance: Appearance? = nil
                    if case .reason(let r) = self.mode { appearance = r.appearance }
                    c.configure(m, appearance: appearance)
                    c.onOpen = { [weak self] in self?.openSession(sid, title: title) }
                    c.onToggle = { [weak self] in self?.toggle(id) }
                    return c
                case .agentNote:
                    let c = cv.dequeueReusableCell(withReuseIdentifier: AgentNoteCell.reuse, for: ip) as! AgentNoteCell
                    c.configure(m)
                    c.onToggle = { [weak self] in self?.toggle(id) }
                    return c
                case .bubble:
                    let c = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuse, for: ip) as! MessageCell
                    c.configure(m)
                    c.onImageTap = { [weak self] v, ref in self?.openImage(ref, from: v) }
                    c.onFileTap = { [weak self] card in self?.preview(card) }
                    c.onLinkTap = { [weak self] url in self?.openLink(url) }
                    c.chips.onTap = { [weak self] chip in self?.open(chip) }
                    return c
                }
            case .request(let rid):
                let c = cv.dequeueReusableCell(withReuseIdentifier: RequestCell.reuse, for: ip) as! RequestCell
                if let r = self.pendingRequests.first(where: { $0.id == rid }) {
                    c.configure(r)
                    c.onAnswer = { [weak self, weak c] answers in self?.answer(r, answers: answers, cell: c) }
                    c.onAction = { [weak self, weak c] action, value in self?.resolve(r, action: action, value: value, cell: c) }
                    c.onOpen = { url in UIApplication.shared.open(url) }
                }
                return c
            case .activity(let id):
                let c = cv.dequeueReusableCell(withReuseIdentifier: ActivityCell.reuse, for: ip) as! ActivityCell
                if let m = self.activityModels[id] {
                    c.configure(m)
                    c.onToggle = { [weak self] in self?.toggle(id) }
                    c.onStep = { [weak self] step in self?.showStep(step) }
                    c.onImageTap = { [weak self] v, ref in self?.openImage(ref, from: v) }
                }
                return c
            case .live:
                let c = cv.dequeueReusableCell(withReuseIdentifier: LiveCell.reuse, for: ip) as! LiveCell
                c.configure(steps: self.liveSteps, text: self.liveText, summaryText: self.liveSummary)
                return c
            }
        }
    }

    private func setUpInputBar() {
        if isReadOnly {
            collectionView.pin(to: view)
            return
        }
        inputBar.delegate = self
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.stopButton.addTarget(self, action: #selector(stopRun), for: .touchUpInside)
        view.addSubview(inputBar)
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        inputBar.onError = { [weak self] msg in self?.showMessage("Dictation", msg) }
        inputBar.plusButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.attachMenuItems() ?? [])
        }])
        choice.reset(to: app.defaultChoice)
        choice.onChange = { [weak self] in
            guard let self else { return }
            self.app.defaultChoice = self.choice.value
            self.updateModelChip(pulse: true)
        }
        updateModelChip()
        observers.append(NotificationCenter.default.addObserver(forName: .modelsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModelChip(); self?.render(animated: false) }
        })
        Task { await app.loadModels() }
    }

    private func setUpJumpButton() {
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(jumpButton)
        let bottom = isReadOnly
            ? jumpButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            : jumpButton.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -12)
        NSLayoutConstraint.activate([bottom, jumpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)])
        jumpButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.scrollToBottom(animated: true)
        }, for: .touchUpInside)
    }

    /// Your finger wins: stop any glide toward new text.
    func scrollViewWillBeginDragging(_ sv: UIScrollView) {
        collectionView.stickToBottom = false
        followAnimator?.stopAnimation(true)
        followAnimator = nil
    }

    /// Show the jump button once the latest message is well out of view.
    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard didInitialScroll else { return }
        let fromBottom = sv.contentSize.height + sv.adjustedContentInset.bottom - (sv.contentOffset.y + sv.bounds.height)
        if fromBottom > 320 { jumpButton.setShown(true) } else if fromBottom < 60 { jumpButton.setShown(false) }
    }

    // MARK: Loading

    private func initialLoad() async {
        do {
            let fromCache = store.loaded
            try await store.loadAll()
            syncChoiceFromConversation()
            render(animated: false)
            // The cache drew the first frame; now catch up quietly on what was said since.
            if fromCache, let (ins, upd) = try? await store.poll(), !(ins.isEmpty && upd.isEmpty) {
                syncChoiceFromConversation()
                render(animated: false)
            }
            updateAvatarState()
            Task { await loadChildEvents() }
            Task { await refreshRequests() }
            view.setNeedsLayout()
            if isReadOnly { Task { await refreshRequests() } }
            Task { await loadActivity() }
            if let sid = sessionId, !isReadOnly {
                let conv = try? await app.api.session(sid)
                conversationSession = conv
                syncChoiceFromConversation()
                let running = LiveHub.shared.running.contains(sid) || conv?.status == "running"
                if running, store.lastVisible?.isMine == true {
                    awaitingReply = true
                    render(animated: true)
                }
            }
        } catch {
            showError(error)
        }
    }

    /// SSE drives updates; this slow loop only covers a dropped stream.
    private func startFallbackPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay: UInt64 = (self?.awaitingReply ?? false) ? 5_000_000_000 : 25_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                await self?.pollOnce()
            }
        }
    }

    private var faviconRefreshScheduled = false

    private func observeLive() {
        observers.append(NotificationCenter.default.addObserver(forName: Favicons.loaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.faviconRefreshScheduled else { return }
                self.faviconRefreshScheduled = true     // several icons often land together: one redraw
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.faviconRefreshScheduled = false
                    self.refreshVisibleLinks()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: LiveHub.resumed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil else { return }
                Task {
                    await self.pollOnce()
                    await self.refreshRequests()
                    if let sid = self.sessionId, !self.isReadOnly, let s = try? await self.app.api.session(sid) {
                        if s.status == "running", !self.awaitingReply { self.liveSince = Date(); self.awaitingReply = true; self.render(animated: true) }
                        if s.status != "running", self.awaitingReply { await self.pollOnce(); self.awaitingReply = false; self.render(animated: true) }
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: LiveHub.sessionEvent, object: nil, queue: .main) { [weak self] n in
            guard let e = n.object as? LiveHub.SessionEvent else { return }
            MainActor.assumeIsolated { self?.handle(e) }
        })
    }

    private func handle(_ e: LiveHub.SessionEvent) {
        if childTitles[e.sessionId] != nil {
            switch e.type {
            case "message.created": Task { await loadChildEvents(only: e.sessionId) }
            case "turn.started": childStatus[e.sessionId] = "running"; syncChildWatchers(); render(animated: true)
            case "turn.finished":
                let st = (e.payload["data"] as? [String: Any])?["status"] as? String
                childStatus[e.sessionId] = st == "cancelled" ? "stopped" : (st == "error" ? "failed" : (st == "suspended" ? "stopped" : "finished"))
                childNow[e.sessionId] = nil
                syncChildWatchers()
                render(animated: true)
            default: break
            }
            return
        }
        guard e.sessionId == sessionId else { return }
        if e.type.hasPrefix("input_request.") { Task { await refreshRequests() }; return }
        if isReadOnly {
            if e.type == "turn.started" { setSessionRunning(true) }
            if e.type == "turn.finished" { Task { await pollOnce(); setSessionRunning(false) } }
        }
        switch e.type {
        case "turn.started":
            if !isReadOnly && !awaitingReply {
                liveSince = Date()
                awaitingReply = true
                render(animated: true)
                if isNearBottom { scrollToBottom(animated: true) }
            }
        case "message.created":
            Task { await pollOnce() }
        case "turn.finished":
            Task {
                await pollOnce()
                // Cancelled or failed turns may leave no reply.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await pollOnce()
                if awaitingReply { awaitingReply = false; render(animated: true) }
            }
        default:
            break
        }
    }

    private func pollOnce() async {
        guard store.loaded else { return }
        // Secrets saved elsewhere send no event: re-check while a secret card is up.
        if pendingRequests.contains(where: { $0.secretRequest != nil }) { Task { await refreshRequests() } }
        guard let (inserted, updated) = try? await store.poll(), !(inserted.isEmpty && updated.isEmpty) else { return }
        let newReplies = store.items.filter { inserted.contains($0.id) && !$0.isMine && !$0.text.isEmpty }
        if awaitingReply, let sent = lastSendDate ?? Optional(liveSince),
           store.items.contains(where: { $0.kind == "reply" && !$0.text.isEmpty && ($0.date ?? .distantPast) > sent.addingTimeInterval(-2) && inserted.contains($0.id) }) {
            awaitingReply = false
        }
        newReplies.forEach { animateIn.insert($0.id) }
        syncChoiceFromConversation()
        if !newReplies.isEmpty, let sid = sessionId, !isReadOnly {
            Task {
                // The session holds the setting the next turn will use; refresh it after each reply.
                if let s = try? await app.api.session(sid) { conversationSession = s; syncChoiceFromConversation() }
            }
        }
        let wasAtBottom = isNearBottom
        if !newReplies.isEmpty, activityTask == nil, let a = activity { _ = try? await a.poll(waitMs: 0) }
        render(animated: true)
        if !newReplies.isEmpty {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            titlePill.avatar.bounce()
            if wasAtBottom { scrollToBottom(animated: true) } else if jumpButton.shown { jumpButton.count += newReplies.count }
        }
    }

    // MARK: Input requests

    /// Requests answered from this phone. Reason can keep listing one as pending for a while after.
    private static var answeredRequests: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "answeredRequests") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(300)), forKey: "answeredRequests") }
    }

    private func refreshRequests() async {
        guard let sid = sessionId, let list = try? await app.api.inputRequests(sid) else { return }
        var pending = list.filter { $0.isPending && !Self.answeredRequests.contains($0.id) }
        // A secret saved anywhere (here, the desktop app, or by the agent) leaves its request "pending"
        // on the server. Once the workspace has that secret, saved after it was asked for, the card goes.
        if pending.contains(where: { $0.secretRequest != nil }), let secrets = try? await app.api.secretNames() {
            pending.removeAll { r in
                guard let name = r.secretRequest?.name, let s = secrets.first(where: { $0.name == name }),
                      let saved = (s.updatedAt ?? s.createdAt).flatMap(ISODate.parse) else { return false }
                guard let asked = r.createdAt.flatMap(ISODate.parse) else { return true }
                return saved >= asked.addingTimeInterval(-1)
            }
        }
        // Several asks for the same secret: only the newest stands.
        var seen = Set<String>()
        pending.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        pending.removeAll { r in
            guard let name = r.secretRequest?.name else { return false }
            return !seen.insert(name).inserted
        }
        // Agents' own sessions never "move past" a card when another agent writes to them, so a card from
        // a sub-session stays pending forever after it carried on. Once that session started a later turn, it's stale.
        let askers = Set(pending.compactMap(\.askedInSessionId)).subtracting([sid])
        if !askers.isEmpty {
            var turnStarted: [String: Date] = [:]
            await withTaskGroup(of: (String, Date?).self) { g in
                for a in askers { g.addTask { [app] in (a, (try? await app.api.session(a))?.startedAt.flatMap(ISODate.parse)) } }
                for await (a, d) in g { if let d { turnStarted[a] = d } }
            }
            pending.removeAll { r in
                guard let a = r.askedInSessionId, let started = turnStarted[a],
                      let asked = r.createdAt.flatMap(ISODate.parse) else { return false }
                return started > asked.addingTimeInterval(1)
            }
        }
        guard pending.map(\.id) != pendingRequests.map(\.id) else { return }
        let isNew = !Set(pending.map(\.id)).subtracting(pendingRequests.map(\.id)).isEmpty
        let stick = isNearBottom
        pendingRequests = pending
        render(animated: true)
        if isNew {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            titlePill.setStatus("Waiting for you")
            if stick { scrollToBottom(animated: true) } else { jumpButton.count += 1 }
        }
    }

    private func answer(_ r: InputRequest, answers: [(selected: [String], text: String?)], cell: RequestCell?) {
        guard let sid = sessionId else { return }
        Task {
            do {
                try await app.api.answer(sid, request: r.id, answers: answers)
                settled(r)
            } catch {
                cell?.resetBusy(); cell?.shake(); showError(error)
            }
        }
    }

    private func resolve(_ r: InputRequest, action: String, value: String?, cell: RequestCell?) {
        guard let sid = sessionId else { return }
        Task {
            do {
                try await app.api.resolve(sid, request: r.id, action: action, value: value)
                settled(r)
            } catch {
                cell?.resetBusy(); cell?.shake(); showError(error)
            }
        }
    }

    /// The card slides away and the Reason picks its work back up.
    private func settled(_ r: InputRequest) {
        Self.answeredRequests.insert(r.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        pendingRequests.removeAll { $0.id == r.id }
        if !isReadOnly && !awaitingReply { liveSince = Date(); awaitingReply = true }
        render(animated: true)
    }

    // MARK: Child Sessions

    /// Each child Session's conversation records what this Reason sent it, with timestamps.
    private func loadChildEvents(only: String? = nil) async {
        guard case .reason(let r) = mode, let parent = r.sessionId else { return }
        if only == nil {
            guard let sessions = try? await app.api.sessions(reasonId: r.id, first: 50) else { return }
            for s in sessions where s.createdBySessionId == parent {
                childTitles[s.sessionId] = s.title ?? "Session"
                childStatus[s.sessionId] = Self.childState(s)
            }
        }
        let ids = only.map { [$0] } ?? Array(childTitles.keys)
        await withTaskGroup(of: Void.self) { g in
            for id in ids {
                g.addTask { @MainActor in
                    let st = self.app.store(.session(id))
                    if st.loaded { _ = try? await st.poll() } else { try? await st.loadAll() }
                }
            }
        }
        syncChildWatchers()
        DiskCache.save("children-" + r.id, childTitles.keys.map { ChildMeta(sessionId: $0, title: childTitles[$0] ?? "", status: childStatus[$0]) })
        let events = buildChildEvents(parent: parent)
        let fresh = Set(events.map(\.id)).subtracting(childEvents.map(\.id))
        // Ones that arrive while the chat is open spring in; nothing changes → nothing moves.
        guard !fresh.isEmpty || events.count != childEvents.count || only == nil else { return }
        if !childEvents.isEmpty { fresh.forEach { animateIn.insert("child-" + $0) } }
        childEvents = events
        render(animated: only != nil)
    }

    private struct ChildMeta: Codable { let sessionId: String; let title: String; let status: String? }

    /// Cached children → cards are part of the very first frame, so nothing gets inserted later.
    private func restoreChildEvents() {
        guard case .reason(let r) = mode, let parent = r.sessionId,
              let metas = DiskCache.load("children-" + r.id, as: [ChildMeta].self) else { return }
        for m in metas { childTitles[m.sessionId] = m.title; childStatus[m.sessionId] = m.status }
        childEvents = buildChildEvents(parent: parent)
    }

    private func buildChildEvents(parent: String) -> [ChildEvent] {
        var events: [ChildEvent] = []
        for (id, title) in childTitles {
            for item in app.store(.session(id)).items where item.role == "user" && item.author?.sessionId == parent {
                let verb = item.author?.via == "sessions_create" || item.kind == "prompt" ? "Started" : "Messaged"
                events.append(ChildEvent(id: item.id, date: item.date, verb: verb, title: title, sessionId: id, text: item.text))
            }
        }
        return events
    }

    private static func childState(_ s: SessionSummary) -> String? {
        switch (s.status, s.outcome) {
        case ("running", _): return "running"
        case ("suspended", _): return "stopped"
        case ("error", _), (_, "failure"): return "failed"
        case ("exit", _): return "finished"
        default: return nil
        }
    }

    // MARK: Tool activity

    private func loadActivity() async {
        guard let a = activity else { return }
        if !a.turns.isEmpty { render(animated: false) }    // from cache
        do { try await a.loadAll() } catch { return }
        render(animated: false)
        if isReadOnly, let sid = sessionId {
            let s = try? await app.api.session(sid)
            setSessionRunning(s?.status == "running" || LiveHub.shared.running.contains(sid))
        }
    }

    private func setSessionRunning(_ running: Bool) {
        guard running != sessionRunning else { return }
        sessionRunning = running
        titlePill.setStatus(running ? "Working…" : nil)
        if running { watchActivity() } else {
            activityTask?.cancel(); activityTask = nil
            Task { _ = try? await activity?.poll(waitMs: 0); render(animated: true) }
        }
        render(animated: true)
    }

    /// Long-polls the event log while the Session works, so each step appears as it starts.
    private func watchActivity() {
        guard activityTask == nil, let a = activity, view.window != nil else { return }
        activityTask = Task { [weak self] in
            while !Task.isCancelled, self?.sessionRunning == true {
                do {
                    if try await a.poll(waitMs: 15000) {
                        guard let self else { return }
                        let stick = self.isNearBottom
                        if let now = a.turns.last?.tools.last {
                            self.titlePill.setStatus([now.title, now.detail].compactMap { $0 }.joined(separator: " "))
                        }
                        self.render(animated: true)
                        if stick { self.scrollToBottom(animated: true) }
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            self?.activityTask = nil
        }
    }

    /// One quiet loop per running child Session: its newest step shows under its card.
    private func syncChildWatchers() {
        guard case .reason = mode, view.window != nil else { return }
        let running = Set(childStatus.filter { $0.value == "running" }.map(\.key))
        for (id, t) in childWatchers where !running.contains(id) { t.cancel(); childWatchers[id] = nil }
        for id in running where childWatchers[id] == nil {
            let a = app.activity(id)
            childWatchers[id] = Task { [weak self] in
                var first = true
                while !Task.isCancelled {
                    let changed = (try? await a.poll(waitMs: first ? 0 : 15000)) ?? false
                    first = false
                    guard let self, !Task.isCancelled else { return }
                    if changed || self.childNow[id] == nil {
                        let step = a.turns.last?.tools.last
                        if step != self.childNow[id] { self.childNow[id] = step; self.render(animated: true) }
                    }
                    if !changed { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                }
            }
        }
    }

    /// Signed URLs for the screenshots this conversation's turns showed, fetched when one is missing.
    private func loadShotFiles() {
        guard !shotsLoading, let sid = sessionId,
              activity?.turns.contains(where: { ($0.shots ?? []).contains { shotFiles[$0.id] == nil } }) == true else { return }
        shotsLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.shotsLoading = false }
            guard let list = try? await self.app.api.sessionAttachments(sid) else { return }
            var changed = false
            for a in list {
                guard let raw = a.url, let url = URL(string: raw), self.shotFiles[a.id] == nil else { continue }
                self.shotFiles[a.id] = (url, a.name ?? url.lastPathComponent)
                changed = true
            }
            if changed { self.render(animated: false) }
        }
    }

    private func showStep(_ step: ActivityStep) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        present(ActivityStepViewController(step: step), animated: true)
    }

    // MARK: Live turn streaming

    private var liveSummary: String? {
        let tools = liveSteps.filter { $0.icon != "brain" }.count
        let secs = Int(Date().timeIntervalSince(liveSince))
        guard tools > 0 || secs > 4 else { return nil }
        var bits = ["Working \(secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s")"]
        if tools > 0 { bits.append("\(tools) step\(tools == 1 ? "" : "s")") }
        return bits.joined(separator: " · ")
    }

    private func startLive() {
        guard liveTask == nil, let sid = sessionId, !isReadOnly else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            var cursor = (try? await self.app.api.latestAttemptCursor(sid)) ?? -1
            while !Task.isCancelled, self.awaitingReply {
                guard let p = try? await self.app.api.events(sid, afterSeq: cursor, waitMs: 20000) else {
                    try? await Task.sleep(nanoseconds: 1_500_000_000); continue
                }
                if let n = p.nextSeq { cursor = n }
                self.ingest(p.items)
            }
            self.liveTask = nil
        }
    }

    /// Streamed events reappear with growing snapshots under the same id: keep the newest.
    private func ingest(_ events: [SessionEventsPage.Event]) {
        let floor = liveSince.addingTimeInterval(-5)
        for e in events {
            if let d = e.createdAt.flatMap(ISODate.parse), d < floor { continue }
            if let old = liveEvents[e.id], old.seq > e.seq { continue }
            liveEvents[e.id] = e
        }
        let ordered = liveEvents.values.sorted { ($0.position ?? $0.seq) < ($1.position ?? $1.seq) }
        var steps: [LiveStep] = []
        var results: [String: SessionEventsPage.EventData] = [:]
        for e in ordered where e.type == "tool_result" { if let id = e.data?.toolUseId { results[id] = e.data } }
        var text: String?
        for e in ordered {
            switch e.type {
            case "tool_use":
                let tool = e.data?.tool ?? e.text ?? "tool"
                let r = e.data?.toolUseId.flatMap { results[$0] }
                if tool == "codemode", let s = Self.sessionStep(code: e.data?.input) {
                    steps.append(LiveStep(id: e.id, icon: "arrow.triangle.branch", title: s.0, detail: s.1, done: r != nil, failed: r?.isError == true))
                } else {
                    steps.append(LiveStep(id: e.id, icon: Self.icon(for: tool), title: Self.title(for: tool),
                                          detail: Self.detail(input: e.data?.input), done: r != nil, failed: r?.isError == true))
                }
            case "reasoning":
                if steps.last?.icon != "brain" {
                    steps.append(LiveStep(id: e.id, icon: "brain", title: "Thinking", detail: nil, done: false, failed: false))
                }
            case "assistant":
                text = e.text
                // Any running "Thinking" before text is done.
                for i in steps.indices where steps[i].icon == "brain" { steps[i].done = true }
            default: break
            }
        }
        // Earlier thinking blocks are finished once something follows them.
        for i in steps.indices.dropLast() where steps[i].icon == "brain" { steps[i].done = true }
        liveSteps = steps
        liveText = text
        if let last = steps.last(where: { !$0.done }) {
            titlePill.setStatus([last.title, last.detail].compactMap { $0 }.joined(separator: " "))
        } else if text != nil {
            titlePill.setStatus("Writing…")
        }
        scheduleLiveRefresh()
    }

    private func scheduleLiveRefresh() {
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.liveRefreshScheduled = false
            var snap = self.dataSource.snapshot()
            guard snap.itemIdentifiers.contains(.live) else { return }
            let cv = self.collectionView!
            // Follow the text only when you're already at the bottom and not touching the list.
            let stick = self.isNearBottom && !cv.isTracking && !cv.isDecelerating
            snap.reconfigureItems([.live])
            // Instant, not animated: these land every fraction of a second, and overlapping
            // layout + scroll animations are what made the list jump.
            UIView.performWithoutAnimation {
                self.dataSource.apply(snap, animatingDifferences: false)
                cv.layoutIfNeeded()
            }
            // New lines: glide down to them (one animation at a time, never stacked).
            if stick { self.followBottom() }
        }
    }

    private var followAnimator: UIViewPropertyAnimator?

    private func followBottom() {
        let target = bottomOffset
        guard abs(collectionView.contentOffset.y - target.y) > 0.5 else { return }
        followAnimator?.stopAnimation(true)
        let a = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut) { self.collectionView.contentOffset = target }
        a.addCompletion { [weak self] _ in self?.followAnimator = nil }
        a.startAnimation()
        followAnimator = a
    }

    private static func icon(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "shell", "codemode": return "terminal"
        case "read": return "doc.text"
        case "edit", "write", "apply_patch": return "pencil"
        case let t where t.contains("browser") || t.contains("web"): return "globe"
        case let t where t.contains("computer"): return "desktopcomputer"
        case let t where t.contains("search") || t.contains("grep"): return "magnifyingglass"
        case let t where t.contains("session"): return "arrow.triangle.branch"
        default: return "wrench.and.screwdriver"
        }
    }

    private static func title(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "exec", "shell": return "Ran"
        case "read": return "Read"
        case "edit", "apply_patch": return "Edited"
        case "write": return "Wrote"
        case "codemode": return "Code"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The Reason drives child Sessions from code: `tools.sessions_create({title: …})`, `tools.sessions_send(…)`.
    private static func sessionStep(code input: String?) -> (String, String?)? {
        guard let input else { return nil }
        let code = ((try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any])?["code"] as? String ?? input
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

    /// The interesting part of a tool's input: a command, a path, a query or a URL.
    private static func detail(input: String?) -> String? {
        guard let input, let d = input.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return input.map { String($0.prefix(80)) }
        }
        for k in ["command", "cmd", "path", "file_path", "file", "query", "url", "pattern", "prompt", "title"] {
            if let v = obj[k] as? String, !v.isEmpty {
                return v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func updateAvatarState() {
        if awaitingReply { titlePill.avatar.state = .working; return }
        let last = store.lastVisible?.date ?? .distantPast
        titlePill.avatar.state = Date().timeIntervalSince(last) > 3 * 3600 ? .sleeping : .idle
    }

    private func runningChanged() {
        inputBar.isRunning = awaitingReply
        defer { updateAvatarState() }
        titlePill.avatar.setThinking(awaitingReply)
        if awaitingReply {
            if lastSendDate.map({ Date().timeIntervalSince($0) < 10 }) != true { liveSince = Date() } else { liveSince = lastSendDate! }
            liveEvents = [:]; liveSteps = []; liveText = nil
            titlePill.setStatus("Thinking…")
            startLive()
        } else {
            titlePill.setStatus(nil)
            liveTask?.cancel(); liveTask = nil
        }
    }

    // MARK: Rendering

    /// "" for this app, a name for another app you typed in, nil when a person didn't type it.
    static func humanSource(_ a: Author?) -> String? {
        guard let a else { return "" }
        if a.kind == "person" {
            switch a.via {
            case "desktop": return "Reason desk"
            case "web": return "the web"
            case "slack": return "Slack"
            case nil, "api": return ""
            case let v?: return v.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        // Apps calling the API for you carry your user id and their name.
        if a.kind == "agent", a.userId != nil, a.via == "api" {
            switch a.originAgent {
            case "reason-ios", nil: return ""
            case "reason-desk": return "Reason desk"
            case let o?: return o.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }
        return nil
    }

    /// The conversation feed sends replies flattened onto one line and cut at 1,500 characters.
    /// The Session's event log has each turn's reply as written, so use that when it's loaded.
    /// The first frame shows only the latest messages, so a long chat opens instantly; the rest is
    /// added (above, out of sight) once it's on screen.
    private var renderWindow: Int? = 60
    private var fullReplies: [String: String] = [:]
    private var fullRepliesKey = ""

    private static func squash(_ s: String, _ n: Int) -> String {
        String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(n))
    }

    private func fullReply(_ text: String) -> String {
        guard text.utf16.count > 80, !text.contains("\n"), let turns = activity?.turns, !turns.isEmpty else { return text }
        let key = "\(turns.count)-\(turns.last?.finalText?.count ?? 0)"
        if fullRepliesKey != key {
            fullRepliesKey = key
            fullReplyMemo = [:]
            fullReplies = [:]
            for t in turns { if let f = t.finalText, f.contains("\n") { fullReplies[Self.squash(f, 160)] = f } }
        }
        if let hit = fullReplyMemo[text] { return hit }
        let r = fullReplies[Self.squash(text, 160)] ?? text
        fullReplyMemo[text] = r
        return r
    }
    private var fullReplyMemo: [String: String] = [:]

    private func displayId(for item: ConversationItem) -> String {
        pending.first(where: { $0.serverId == item.id })?.localId ?? item.id
    }

    /// Matches our optimistic sends to the server's echo so their rows keep the same identity.
    private func reconcilePending() {
        let claimed = Set(pending.compactMap(\.serverId))
        for i in pending.indices where pending[i].serverId == nil && !pending[i].failed {
            if let match = store.items.first(where: {
                $0.isMine && !claimed.contains($0.id) && $0.text == pending[i].text
                    && ($0.date ?? .distantFuture) > pending[i].date.addingTimeInterval(-120)
            }) {
                pending[i].serverId = match.id
            }
        }
    }

    private func modelLabel(_ id: String?) -> String? {
        guard let id else { return nil }
        if let m = app.models.first(where: { $0.id == id }) { return m.displayName }
        // "byok:anthropic:claude-sonnet-5-5" → "Claude Sonnet 5.5", "openai/gpt-6-luna" → "GPT 6 Luna"
        var raw = String(id.split(separator: "/").last ?? Substring(id))
        raw = String(raw.split(separator: ":").last ?? Substring(raw))
        raw = raw.replacingOccurrences(of: #"(?<=\d)-(?=\d)"#, with: ".", options: .regularExpression)
        return raw.replacingOccurrences(of: "-", with: " ").capitalized
            .replacingOccurrences(of: "Gpt", with: "GPT").replacingOccurrences(of: "Glm", with: "GLM")
    }

    private func render(animated: Bool, completion: (() -> Void)? = nil) {
        reconcilePending()
        struct Entry {
            let id: String; let text: String; let images: [Markdown.ImageRef]; let mine: Bool; let date: Date?
            let failed: Bool; let via: String?; let fromTitle: String?; let run: RunInfo?; let pendingState: String?
            var style: MessageModel.Style = .bubble
            var chips: [LinkChip] = []
            var files: [AttachmentRef] = []
            var source: String?     // where you typed it, when not on this iPhone
        }
        let me = app.me?.serviceUserName
        var visible = store.visibleItems
        if let w = renderWindow, visible.count > w { visible = Array(visible.suffix(w)) }
        let windowStart = renderWindow != nil ? visible.first?.date : nil
        var entries: [Entry] = visible.map { item in
            let a = item.author
            let chips = LinkChip.extract(from: item.kind == "reply" ? fullReply(item.text) : item.text)
            // Child Session report: "Session "X" finished.\n<result>…</result>"
            if a?.via == "session_report" {
                let (title, state, body) = Self.parseReport(item.text, fallbackTitle: a?.title)
                let (clean, images) = Markdown.extractImages(body)
                return Entry(id: item.id, text: clean, images: images, mine: false, date: item.date, failed: state == .failed, via: nil,
                             fromTitle: nil, run: nil, pendingState: nil, style: .report(title: title, state: state, sessionId: a?.sessionId), chips: chips)
            }
            if a?.kind == "system" {
                return Entry(id: item.id, text: item.text, images: [], mine: false, date: item.date, failed: false, via: nil,
                             fromTitle: nil, run: nil, pendingState: nil, style: .notice)
            }
            // Typed by you in another app (Reason desk, the web): your own bubble, labelled with where.
            if item.role == "user", let src = Self.humanSource(a) {
                let files = (item.attachments ?? []).enumerated().map { AttachmentRef($1, index: $0 + 1) }
                let (text, images) = Markdown.extractImages(item.text)
                return Entry(id: displayId(for: item), text: text, images: images, mine: true, date: item.date, failed: false,
                             via: nil, fromTitle: nil, run: nil, pendingState: nil, chips: chips, files: files,
                             source: src.isEmpty ? nil : src)
            }
            // Sent by another agent (a Session, an automation): collapsed "Message from …" like desktop.
            if item.role == "user", a?.kind == "agent", a?.originAgent != "reason-ios" {
                let from = [a?.originAgent ?? a?.title ?? a?.via?.replacingOccurrences(of: "_", with: " ") ?? "an agent",
                            a?.userId != nil ? me : nil].compactMap { $0 }.joined(separator: " · ")
                return Entry(id: item.id, text: item.text, images: [], mine: true, date: item.date, failed: false, via: "note",
                             fromTitle: nil, run: nil, pendingState: nil, style: .agentNote(from: from), chips: chips)
            }
            let (text, images) = Markdown.extractImages(item.kind == "reply" ? fullReply(item.text) : item.text)
            let from = !item.isMine && item.kind == "message" ? a?.title : nil
            let files = (item.attachments ?? []).enumerated().map { AttachmentRef($1, index: $0 + 1) }
            let empty = item.text.isEmpty && files.isEmpty
            return Entry(id: displayId(for: item), text: empty ? "This turn failed." : text, images: images,
                         mine: item.isMine, date: item.date, failed: item.isFailedReply, via: nil,
                         fromTitle: from, run: item.run, pendingState: nil, chips: chips, files: files)
        }
        if !childEvents.isEmpty {
            let extra = childEvents.filter { c in windowStart.map { (c.date ?? .distantPast) >= $0 } ?? true }.map { c in
                Entry(id: "child-" + c.id, text: c.text, images: [], mine: false, date: c.date, failed: false, via: nil,
                      fromTitle: nil, run: nil, pendingState: nil,
                      style: .childEvent(verb: c.verb, title: c.title, sessionId: c.sessionId, status: childStatus[c.sessionId]))
            }
            // Stable merge by time; undated items keep their place.
            var merged: [Entry] = []
            var queue = extra.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            for e in entries {
                while let first = queue.first, let fd = first.date, let ed = e.date, fd < ed { merged.append(queue.removeFirst()) }
                merged.append(e)
            }
            entries = merged + queue
        }
        for p in pending where p.serverId == nil {
            entries.append(Entry(id: p.localId, text: p.text, images: [], mine: true, date: p.date, failed: p.failed,
                                 via: nil, fromTitle: nil, run: nil,
                                 pendingState: p.failed ? "Not delivered · Tap to retry" : (p.files.isEmpty ? nil : "Uploading…"),
                                 files: p.files.map(AttachmentRef.init)))
        }

        // Each turn's activity sits just above the reply it produced: the first reply at or after the
        // turn's last event, and before the next turn began. A turn with no reply yet trails at the end.
        var activityBefore: [String: ActivityTurn] = [:]
        var trailingTurn: ActivityTurn?
        if let turns = activity?.turns, !turns.isEmpty {
            let replies = entries.filter { e in
                guard !e.mine, e.date != nil, e.pendingState == nil else { return false }
                if case .bubble = e.style { return true }
                return false
            }
            var j = 0
            for (k, t) in turns.enumerated() {
                let nextStart = k + 1 < turns.count ? turns[k + 1].start : nil
                while j < replies.count, replies[j].date! < t.end.addingTimeInterval(-5) { j += 1 }
                if j < replies.count, nextStart.map({ replies[j].date! < $0.addingTimeInterval(5) }) ?? true {
                    if worthShowing(t) { activityBefore[replies[j].id] = t }
                    j += 1
                } else if k == turns.count - 1, worthShowing(t), !(awaitingReply && !isReadOnly) {
                    trailingTurn = t
                }
            }
        }
        var newActivity: [String: ActivityModel] = [:]
        /// In a Reason's chat, turns that only talked to Sessions are already told by the "Sent a message" cards.
        func worthShowing(_ t: ActivityTurn) -> Bool {
            if !(t.shots ?? []).isEmpty { return true }
            if isReadOnly { return !t.tools.isEmpty }
            return t.tools.contains { ![.session, .code, .tool].contains($0.kind) }
        }
        // Screenshots already embedded in a reply (published with media_publish_file) aren't repeated.
        let shownFiles = Set(entries.flatMap { $0.images.map { $0.url.lastPathComponent } })
        func activityRow(_ t: ActivityTurn, live: Bool) -> Row {
            let id = "act-\(sessionId ?? "")-\(t.attempt)"
            let shots: [Markdown.ImageRef] = (t.shots ?? []).compactMap { s in
                guard let f = shotFiles[s.id], !shownFiles.contains(f.name) else { return nil }
                return Markdown.ImageRef(url: f.url, alt: s.caption ?? "Screenshot", aspect: s.aspect)
            }
            newActivity[id] = ActivityModel(id: id, turn: t, expanded: expanded.contains(id), live: live, shots: shots)
            return .activity(id)
        }

        var rows: [Row] = []
        var lastFooterModel: String? = nil
        var newModels: [String: MessageModel] = [:]
        var newStamps: [String: String] = [:]
        var prevDate: Date?
        func gapBreak(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return false }
            return b.timeIntervalSince(a) > 3600
        }
        // Request cards sit where they were asked, as Reason shows them, not pinned under later messages.
        var requestQueue = pendingRequests.filter(\.isPending).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        for (i, e) in entries.enumerated() {
            if let d = e.date {
                while let r = requestQueue.first, let asked = r.createdAt.flatMap(ISODate.parse), asked < d {
                    rows.append(.request(r.id)); requestQueue.removeFirst()
                }
            }
            let prev = i > 0 ? entries[i - 1] : nil
            let next = i + 1 < entries.count ? entries[i + 1] : nil
            var stamped = false
            if let d = e.date, prevDate == nil || gapBreak(prevDate, d) {
                let sid = "stamp-" + e.id
                newStamps[sid] = ISODate.separator(d)
                rows.append(.stamp(sid))
                stamped = true
            }
            if let d = e.date { prevDate = d }
            func isBubble(_ x: Entry?) -> Bool { if case .bubble? = x?.style { return true }; return false }
            let joinTop = !stamped && isBubble(prev) && isBubble(e) && prev!.mine == e.mine && prev!.source == e.source && !gapBreak(prev!.date, e.date)
            let joinBottom = isBubble(next) && isBubble(e) && next!.mine == e.mine && next!.source == e.source && !gapBreak(e.date, next!.date)

            var header: String?
            if !joinTop, let t = e.fromTitle { header = "From \(t)" }
            var footer: String?
            if let s = e.pendingState { footer = s }
            else if !joinBottom {
                let time = e.date.map { ISODate.listStamp($0) }
                // No per-message footers: times live in the separators, the model in the composer.
                // Only a failure is worth a line.
                if !e.mine, e.failed { footer = "Failed" + (time.map { " · \($0)" } ?? "") }
                if e.mine, let src = e.source { footer = "Sent from \(src)" }
                _ = lastFooterModel
            }
            let gap: CGFloat = stamped ? 0 : (joinTop ? 3 : 14)
            var model = MessageModel(id: e.id, text: e.text, mine: e.mine, joinTop: joinTop, joinBottom: joinBottom,
                                     failed: e.failed, header: header, footer: footer, images: e.images, topGap: gap)
            model.style = e.style
            model.chips = e.chips
            model.files = e.files
            model.expanded = expanded.contains(e.id)
            if case .childEvent(_, _, let csid, let st) = e.style, st == "running",
               !entries[(i + 1)...].contains(where: { if case .childEvent(_, _, csid, _) = $0.style { return true }; return false }) {
                model.now = childNow[csid]   // the latest card for a running child shows what it's doing
            }
            if case .report = e.style { model.footer = e.date.map(ISODate.listStamp) }
            newModels[e.id] = model
            if let t = activityBefore[e.id] {
                if var m = newModels[e.id] { m.topGap = 4; newModels[e.id] = m }
                rows.append(activityRow(t, live: false))
            }
            rows.append(.message(e.id))
        }
        if let t = trailingTurn { rows.append(activityRow(t, live: isReadOnly && sessionRunning)) }
        for r in requestQueue { rows.append(.request(r.id)) }
        if awaitingReply && !suppressLive && !isReadOnly { rows.append(.live) }

        var changed = newModels.filter { models[$0.key] != nil && models[$0.key] != $0.value }.map { Row.message($0.key) }
        changed += newActivity.filter { activityModels[$0.key] != nil && activityModels[$0.key] != $0.value }.map { Row.activity($0.key) }
        models = newModels
        activityModels = newActivity
        loadShotFiles()
        stamps = newStamps

        var snap = NSDiffableDataSourceSnapshot<Int, Row>()
        snap.appendSections([0])
        snap.appendItems(rows)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snap.reconfigureItems(changed.filter { existing.contains($0) && rows.contains($0) })
        // Keep the reader where they are. Only appends at the end may animate; anything that lands
        // above (late cards, edited items, re-measured rows) is applied in place and the view re-anchored.
        let oldRows = dataSource.snapshot().itemIdentifiers.filter { $0 != .live }
        let appendOnly = Array(rows.filter { $0 != .live }.prefix(oldRows.count)) == oldRows
        let cv = collectionView!
        let userMoving = cv.isTracking || cv.isDecelerating
        guard didInitialScroll, !oldRows.isEmpty, !userMoving else {
            dataSource.apply(snap, animatingDifferences: animated && appendOnly && !UIAccessibility.isReduceMotionEnabled, completion: completion)
            return
        }
        let wasAtBottom = isNearBottom || cv.stickToBottom
        var anchor: (Row, CGFloat)?
        if !wasAtBottom {
            let visible = cv.indexPathsForVisibleItems.sorted()
            if let ip = visible.first(where: { (cv.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > cv.contentOffset.y + cv.adjustedContentInset.top }),
               let row = dataSource.itemIdentifier(for: ip), let a = cv.layoutAttributesForItem(at: ip) {
                anchor = (row, a.frame.minY - cv.contentOffset.y)
            }
        }
        if appendOnly && animated && !UIAccessibility.isReduceMotionEnabled {
            dataSource.apply(snap, animatingDifferences: true, completion: completion)
            return
        }
        UIView.performWithoutAnimation {
            dataSource.apply(snap, animatingDifferences: false)
            cv.layoutIfNeeded()
            if wasAtBottom {
                pinToLastItem()
            } else if let (row, y) = anchor, let ip = dataSource.indexPath(for: row), let a = cv.layoutAttributesForItem(at: ip) {
                cv.contentOffset.y = a.frame.minY - y
            }
        }
        completion?()
    }

    private var isNearBottom: Bool {
        let cv = collectionView!
        return cv.contentOffset.y + cv.bounds.height - cv.adjustedContentInset.bottom > cv.contentSize.height - 120
    }

    private var bottomOffset: CGPoint {
        let cv = collectionView!
        cv.layoutIfNeeded()
        let y = max(-cv.adjustedContentInset.top, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
        return CGPoint(x: 0, y: y)
    }

    /// Self-sizing cells start at estimated heights, so a single jump to the bottom lands short.
    private func pinToLastItem() {
        let cv = collectionView!
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        var lastHeight: CGFloat = -1
        for _ in 0..<6 {
            cv.layoutIfNeeded()
            cv.scrollToItem(at: IndexPath(item: count - 1, section: 0), at: .bottom, animated: false)
            cv.layoutIfNeeded()
            if cv.contentSize.height == lastHeight { break }
            lastHeight = cv.contentSize.height
        }
        cv.contentOffset = bottomOffset
    }

    private func scrollToBottom(animated: Bool) {
        let target = bottomOffset
        if animated {
            let a = UIViewPropertyAnimator(duration: 0.45, timingParameters: Theme.spring)
            a.addAnimations {
                self.collectionView.contentOffset = target
                self.collectionView.layoutIfNeeded()
            }
            a.startAnimation()
        } else {
            collectionView.contentOffset = target
        }
    }

    // MARK: Entrance animation for incoming messages

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if let c = cell as? ChildEventCell, case .message(let id)? = dataSource.itemIdentifier(for: ip),
           animateIn.remove(id) != nil, !UIAccessibility.isReduceMotionEnabled {
            // Lifts off from the Reason's side, like a message being handed over.
            c.layoutIfNeeded()
            let v = c.column
            v.alpha = 0
            v.transform = CGAffineTransform(translationX: -24, y: 18).scaledBy(x: 0.92, y: 0.92)
            UIViewPropertyAnimator(duration: 0.65, dampingRatio: 0.74) {
                v.alpha = 1
                v.transform = .identity
            }.startAnimation()
            return
        }
        guard case .message(let id)? = dataSource.itemIdentifier(for: ip), animateIn.remove(id) != nil,
              let c = cell as? MessageCell, !UIAccessibility.isReduceMotionEnabled else { return }
        // Plain text settles in where the live text was: a short fade and lift, no scaling.
        let v = c.column
        v.alpha = 0
        v.transform = CGAffineTransform(translationX: 0, y: 6)
        UIViewPropertyAnimator(duration: 0.35, curve: .easeOut) {
            v.transform = .identity
            v.alpha = 1
        }.startAnimation()
    }

    // MARK: Send — the flying bubble

    func inputBarDidSend(_ bar: InputBar, text: String) {
        guard case .reason = mode else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let origin = bar.textView.convert(bar.textView.bounds, to: view)
        let files = bar.takeFiles()
        bar.clear()
        // The API wants message text; an attachments-only send says what it carries.
        let text = !text.isEmpty ? text : (files.count == 1 ? "Attached \(files[0].name)" : "Attached \(files.count) files")

        let localId = "local-" + UUID().uuidString
        pending.append(Pending(localId: localId, text: text, date: Date(), files: files))
        lastSendDate = Date()
        suppressLive = true
        awaitingReply = true

        let cv = collectionView!
        let oldOffset = cv.contentOffset
        render(animated: false)
        cv.layoutIfNeeded()

        // Peek at the final layout to find where the bubble lands, then rewind.
        let finalOffset = bottomOffset
        cv.contentOffset = finalOffset
        cv.layoutIfNeeded()
        guard let ip = dataSource.indexPath(for: .message(localId)),
              let cell = cv.cellForItem(at: ip) as? MessageCell, files.isEmpty else {
            suppressLive = false
            render(animated: true)
            scrollToBottom(animated: true)
            send(localId: localId, text: text, files: files)
            return
        }
        cell.layoutIfNeeded()
        let target = cell.bubble.convert(cell.bubble.bounds, to: view)
        let labelFrame = cell.label.convert(cell.label.bounds, to: cell.bubble)
        cell.contentView.alpha = 0
        cv.contentOffset = oldOffset
        cv.layoutIfNeeded()

        // The flier: starts as the typed text, ends as the outgoing bubble.
        let flier = UIView(frame: origin)
        flier.backgroundColor = Theme.mineBubble.resolvedColor(with: traitCollection).withAlphaComponent(0)
        flier.layer.cornerRadius = BubbleView.radius
        flier.layer.cornerCurve = .continuous
        flier.clipsToBounds = true
        let inkLabel = UILabel()
        inkLabel.numberOfLines = 0
        inkLabel.attributedText = Markdown.render(text, color: Theme.theirsText, linkColor: .link)
        let paperLabel = UILabel()
        paperLabel.numberOfLines = 0
        paperLabel.attributedText = cell.rendered ?? NSAttributedString(string: text)
        paperLabel.alpha = 0
        let start = CGPoint(x: bar.textView.textContainerInset.left + 5, y: bar.textView.textContainerInset.top)
        for l in [inkLabel, paperLabel] {
            l.frame = CGRect(origin: start, size: labelFrame.size)
            flier.addSubview(l)
        }
        view.addSubview(flier)

        let animator = UIViewPropertyAnimator(duration: 0.52, dampingRatio: 0.8)
        animator.addAnimations {
            flier.frame = target
            flier.backgroundColor = Theme.mineBubble.resolvedColor(with: self.traitCollection)
            for l in [inkLabel, paperLabel] { l.frame = labelFrame }
            cv.contentOffset = finalOffset
            cv.layoutIfNeeded()
        }
        animator.addAnimations({
            inkLabel.alpha = 0
            paperLabel.alpha = 1
        }, delayFactor: 0.1)
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            if let ip = self.dataSource.indexPath(for: .message(localId)), let c = self.collectionView.cellForItem(at: ip) {
                c.contentView.alpha = 1
            }
            UIView.animate(withDuration: 0.08, animations: { flier.alpha = 0 }) { _ in flier.removeFromSuperview() }
            self.suppressLive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard self.awaitingReply else { return }
                self.render(animated: true)
                self.scrollToBottom(animated: true)
            }
        }
        animator.startAnimation()

        send(localId: localId, text: text, files: [])
    }

    private func send(localId: String, text: String, files: [LocalFile]) {
        guard case .reason(let r) = mode else { return }
        let o = overrides()
        Task {
            do {
                let resp = try await app.api.sendReasonMessage(
                    r.id, text: text, clientId: localId, model: o.model, source: o.source, effort: o.effort, speed: o.speed, files: files)
                if let sid = resp.sessionId, sessionId != sid {
                    sessionId = sid
                    liveTask?.cancel(); liveTask = nil
                }
                startLive()
                await pollOnce()
            } catch {
                if let i = pending.firstIndex(where: { $0.localId == localId }) { pending[i].failed = true }
                awaitingReply = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                render(animated: true)
                showError(error)
            }
        }
    }

    private func retry(localId: String) {
        guard let i = pending.firstIndex(where: { $0.localId == localId }) else { return }
        let text = pending[i].text
        let files = pending[i].files
        pending.remove(at: i)
        render(animated: true)
        inputBar.textView.text = text
        inputBar.add(files)
        inputBarDidSend(inputBar, text: text)
    }

    func inputBarDidChangeHeight(_ bar: InputBar) {}

    @objc private func stopRun() {
        guard let sid = sessionId else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        Task {
            try? await app.api.cancel(sid)
            awaitingReply = false
            render(animated: true)
        }
    }

    // MARK: Model picker

    /// Follow the model the conversation last ran on, unless the user has picked something else since.
    private func syncChoiceFromConversation() {
        guard !isReadOnly else { return }
        let lastRun = store.items.last(where: { $0.kind == "reply" && $0.run?.model != nil })?.run
        guard let v = Self.currentSetting(session: conversationSession, lastRun: lastRun, reason: reasonForChoice),
              v != sessionChoice else { return }
        let userPickedOther = sessionChoice != nil && choice.value != sessionChoice
        sessionChoice = v
        if !userPickedOther {
            let onChange = choice.onChange
            choice.onChange = nil
            choice.reset(to: v)
            choice.onChange = onChange
            updateModelChip()
        }
    }

    private var reasonForChoice: Reason? { if case .reason(let r) = mode { return r }; return nil }

    /// What the next turn will use if we send no override, as the desktop shows it:
    /// the session's model and effort, the account the last run used (same model), else the Reason's default.
    static func currentSetting(session: SessionSummary?, lastRun: RunInfo?, reason: Reason?) -> ModelChoice.Value? {
        let fromRun = ModelChoice.from(run: lastRun)
        guard let model = session?.model ?? fromRun?.model ?? reason?.defaultModel else { return nil }
        let source = fromRun?.model == model ? fromRun?.source : nil
        let effort = session?.reasoningEffort ?? (fromRun?.model == model ? fromRun?.effort : nil) ?? reason?.defaultReasoningEffort
        return ModelChoice.Value(model: model, source: model.hasPrefix("byok:") ? source : nil, effort: effort,
                                 fast: fromRun?.model == model ? (fromRun?.fast ?? false) : false)
    }

    /// Only send what differs from the conversation: a model override starts a new run.
    private func overrides() -> (model: String?, source: String?, effort: String?, speed: String?) {
        let v = choice.value
        let base = sessionChoice
        var model: String? = nil, source: String? = nil
        if let m = v.model, m != base?.model || v.source != base?.source { model = m; source = v.source }
        let effort = (v.effort != nil && v.effort != base?.effort) || model != nil ? v.effort : nil
        let speed = v.fast && choice.currentModel(app)?.supportsFast == true ? "fast" : nil
        return (model, source, effort, speed)
    }

    private func updateModelChip(pulse: Bool = false) {
        inputBar.setModel(choice.currentModel(app), effort: choice.effort, fast: choice.fast)
        inputBar.modelButton.menu = ModelMenu.modelMenu(app: app, choice: choice) { [weak self] in
            guard let self else { return }
            self.inputBarDidTapModel(self.inputBar)
        }
        inputBar.effortButton.menu = ModelMenu.effortMenu(app: app, choice: choice)
        if pulse { inputBar.pulseModelChip() }
    }

    func inputBarDidTapModel(_ bar: InputBar) {
        let picker = ModelPickerViewController(choice: choice)
        picker.onChange = { [weak self] in self?.updateModelChip(pulse: true) }
        picker.focusSearch = true
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = 28
        }
        present(nav, animated: true)
    }

    // MARK: Attachments

    private func attachMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.pickPhotos() },
        ]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            items.append(UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in self?.openCamera() })
        }
        items.append(UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in self?.pickFiles() })
        let pb = UIPasteboard.general
        if pb.hasImages || pb.hasURLs {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteAttachments() })
        }
        return items
    }

    private func pickPhotos() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = LocalFile.maxCount - inputBar.files.count
        cfg.filter = .any(of: [.images, .videos, .livePhotos, .screenshots])
        cfg.preferredAssetRepresentationMode = .current
        cfg.selection = .ordered
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func openCamera() {
        Task {
            guard await Permissions.ensure(.camera, from: self) else { return }
            presentCamera()
        }
    }

    private func presentCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pasteAttachments() {
        let pb = UIPasteboard.general
        if let images = pb.images, !images.isEmpty {
            inputBar.add(images.enumerated().compactMap { i, img in
                img.pngData().flatMap { try? LocalFile.writing($0, name: "Pasted image\(i == 0 ? "" : " \(i + 1)").png", type: .png) }
            })
        } else if let urls = pb.urls {
            let fileURLs = urls.filter(\.isFileURL)
            inputBar.add(fileURLs.compactMap { try? LocalFile.importing($0) })
            let links = urls.filter { !$0.isFileURL }.map(\.absoluteString)
            if !links.isEmpty {
                inputBar.textView.text = ([inputBar.textView.text ?? ""] + links).filter { !$0.isEmpty }.joined(separator: " ")
                inputBar.textViewDidChange(inputBar.textView)
            }
        }
    }

    // Quick Look for files on messages (downloaded first when remote).
    private var previewURL: URL?

    private func preview(_ card: FileCardView) {
        guard let url = card.ref.url else { return }
        if url.isFileURL { showQuickLook(url); return }
        card.setLoading(true)
        Task {
            defer { card.setLoading(false) }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)-\(card.ref.name)")
                try FileManager.default.moveItem(at: tmp, to: dest)
                showQuickLook(dest)
            } catch {
                showError(error)
            }
        }
    }

    private func showQuickLook(_ url: URL) {
        previewURL = url
        let ql = QLPreviewController()
        ql.dataSource = self
        present(ql, animated: true)
    }

    // MARK: Voice

    func inputBar(_ bar: InputBar, transcribe audio: Data) async throws -> String {
        try await app.api.transcribe(audio: audio, contentType: VoiceRecorder.contentType).transcript
    }

    // MARK: Interaction

    /// "Session "Title" finished.\n<result>\n…\n</result>" → (title, ok, body)
    static func parseReport(_ text: String, fallbackTitle: String?) -> (String, ReportState, String) {
        var title = fallbackTitle ?? "Session"
        var state = ReportState.finished
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if let r = firstLine.range(of: #"Session "(.+)" [\w ]+"#, options: .regularExpression) {
            let line = String(firstLine[r])
            if let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                title = String(line[line.index(after: q1)..<q2])
                let verb = line[line.index(after: q2)...].trimmingCharacters(in: .whitespaces)
                state = ReportState(verb: verb)
            }
        }
        var body = text
        if let a = text.range(of: "<result>") {
            body = String(text[a.upperBound...])
            if let b = body.range(of: "</result>") { body = String(body[..<b.lowerBound]) }
        } else if firstLine.hasPrefix("Session ") {
            body = String(text.dropFirst(firstLine.count))
        }
        return (title, state, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func toggle(_ id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        render(animated: true)
    }

    private func openSession(_ id: String, title: String) {
        navigationController?.pushViewController(ChatViewController(mode: .session(id: id, title: title)), animated: true)
    }

    /// A link tapped inside a message: Reason sessions open here, everything else in its app or Safari.
    private func openLink(_ url: URL) {
        if let chip = LinkChip.extract(from: url.absoluteString).first, case .session = chip.kind {
            open(chip)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// A site icon arrived: redraw the messages on screen that link to it (sizes don't change).
    private func refreshVisibleLinks() {
        var snap = dataSource.snapshot()
        let rows = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }.filter {
            if case .message = $0 { return true }; return false
        }
        guard !rows.isEmpty else { return }
        snap.reconfigureItems(rows)
        UIView.performWithoutAnimation { dataSource.apply(snap, animatingDifferences: false) }
    }

    private func open(_ chip: LinkChip) {
        switch chip.kind {
        case .session(let sid): openSession(sid, title: chip.title == "Open session" ? "Session" : chip.title)
        case .pullRequest, .preview, .link: UIApplication.shared.open(chip.url)
        }
    }

    private func openImage(_ ref: Markdown.ImageRef, from view: UIImageView) {
        guard view.image != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        present(ImageViewerController(ref: ref, source: view), animated: true)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        guard case .message(let id)? = dataSource.itemIdentifier(for: ip) else { return }
        if pending.contains(where: { $0.localId == id && $0.failed }) { retry(localId: id) }
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first, case .message(let id)? = dataSource.itemIdentifier(for: ip),
              let m = models[id], !m.text.isEmpty else { return nil }
        // Agent replies are selectable text: holding on them selects, so no menu there.
        if !m.mine, case .bubble = m.style { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = m.text },
                UIAction(title: "Select Text", image: UIImage(systemName: "character.cursor.ibeam")) { _ in self?.presentSelectable(m.text) },
            ]
            let links = Markdown.links(in: Markdown.render(m.text, color: .label, linkColor: .link))
            if !links.isEmpty {
                actions.append(UIMenu(title: "Links", image: UIImage(systemName: "link"), children: links.prefix(8).map { title, url in
                    UIAction(title: title, subtitle: url.host) { _ in UIApplication.shared.open(url) }
                }))
            }
            if self?.pending.contains(where: { $0.localId == id && $0.failed }) == true {
                actions.append(UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { _ in self?.retry(localId: id) })
            }
            return UIMenu(children: actions)
        }
    }

    /// A sheet with the message as selectable text, for picking out part of it.
    private func presentSelectable(_ text: String) {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let tv = UITextView()
        tv.isEditable = false
        tv.font = .systemFont(ofSize: 17)
        tv.text = text
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 18, bottom: 24, right: 18)
        tv.backgroundColor = .clear
        vc.view.addSubview(tv)
        tv.pin(to: vc.view)
        let nav = UINavigationController(rootViewController: vc)
        vc.title = "Select Text"
        vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(nav, animated: true) {
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: 0, length: (text as NSString).length)
        }
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, highlightPreviewForItemAt ip: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: ip)
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfiguration config: UIContextMenuConfiguration, dismissalPreviewForItemAt ip: IndexPath) -> UITargetedPreview? {
        bubblePreview(at: ip)
    }

    private func bubblePreview(at ip: IndexPath) -> UITargetedPreview? {
        guard let c = collectionView.cellForItem(at: ip) as? MessageCell, !c.bubble.isHidden else { return nil }
        let p = UIPreviewParameters()
        p.visiblePath = c.bubble.path()
        p.backgroundColor = .clear
        return UITargetedPreview(view: c.bubble, parameters: p)
    }

    // MARK: Info

    @objc private func showInfo() {
        guard case .reason(let r) = mode else { return }
        let info = ReasonInfoViewController(reason: r)
        info.onOpenSession = { [weak self] s in
            self?.dismiss(animated: true) {
                self?.navigationController?.pushViewController(
                    ChatViewController(mode: .session(id: s.sessionId, title: s.title ?? "Session")), animated: true)
            }
        }
        info.onOpenImage = { [weak self] ref, v in
            self?.presentedViewController?.present(ImageViewerController(ref: ref, source: v), animated: true)
        }
        let nav = UINavigationController(rootViewController: info)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.preferredCornerRadius = 28
        }
        present(nav, animated: true)
    }

    private func showMessage(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    private func showError(_ error: Error) {
        showMessage("Something went wrong", error.localizedDescription)
    }
}

// MARK: - Floating title pill (desktop style)

final class TitlePill: UIControl {
    let avatar = AvatarView()
    private let name = UILabel()
    private let status = UILabel()
    private let bg = UIView()
    private var avatarWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        bg.backgroundColor = Theme.card
        bg.layer.cornerCurve = .continuous
        bg.layer.borderWidth = 1 / UIScreen.main.scale
        bg.isUserInteractionEnabled = false
        Theme.shadow(bg.layer, radius: 10, opacity: 0.07, y: 2)
        addSubview(bg)
        bg.pin(to: self)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabel
        status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        let texts = UIStackView(arrangedSubviews: [name, status])
        texts.axis = .vertical
        texts.alignment = .leading
        let row = UIStackView(arrangedSubviews: [avatar, texts])
        row.spacing = 7
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 5, left: 6, bottom: 5, right: 14))
        avatarWidth = avatar.widthAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            avatarWidth,
            avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),
            texts.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: TitlePill, _: UITraitCollection) in v.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStroke() { bg.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }

    override func layoutSubviews() {
        super.layoutSubviews()
        bg.layer.cornerRadius = bounds.height / 2
    }

    func configure(name: String, appearance: Appearance?, showsAvatar: Bool = true) {
        self.name.text = name
        avatar.configure(appearance)
        avatar.isHidden = !showsAvatar
    }

    func setStatus(_ text: String?) {
        let show = text != nil
        if show { status.text = text }
        guard status.isHidden == show else { return }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.status.isHidden = !show
            self.status.alpha = show ? 1 : 0
            self.superview?.layoutIfNeeded()
            self.layoutIfNeeded()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            }
        }
    }
}

extension ChatViewController: PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate, QLPreviewControllerDataSource {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider)
        guard !providers.isEmpty else { return }
        Task { @MainActor in
            let r = await ItemImporter.load(providers)
            inputBar.add(r.files)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        inputBar.add(urls.compactMap { try? LocalFile.importing($0) })
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let movie = info[.mediaURL] as? URL, let f = try? LocalFile.importing(movie, type: .movie) {
            inputBar.add([f])
        } else if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.9),
                  let f = try? LocalFile.writing(data, name: "Photo.jpg", type: .jpeg) {
            inputBar.add([f])
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }
}
