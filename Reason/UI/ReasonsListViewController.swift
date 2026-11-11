import UIKit

final class ReasonCell: UICollectionViewListCell {
    let avatar = AvatarView()
    let name = UILabel()
    let preview = UILabel()
    let stamp = UILabel()
    let badge = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        preview.font = .systemFont(ofSize: 14)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 1
        stamp.font = .systemFont(ofSize: 12)
        stamp.textColor = .tertiaryLabel
        stamp.setContentHuggingPriority(.required, for: .horizontal)
        stamp.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 5
        badge.isHidden = true

        for v in [avatar, name, preview, stamp, badge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 10),
            badge.heightAnchor.constraint(equalToConstant: 10),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatar.widthAnchor.constraint(equalToConstant: 42),
            avatar.heightAnchor.constraint(equalToConstant: 42),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatar.bottomAnchor, constant: 10),

            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            name.topAnchor.constraint(equalTo: avatar.topAnchor, constant: 2),
            stamp.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            stamp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stamp.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: preview.bottomAnchor, constant: 12),
        ])
        separatorLayoutGuide.leadingAnchor.constraint(equalTo: name.leadingAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateConfiguration(using state: UICellConfigurationState) {
        // Desktop-style rounded selection instead of a full-bleed highlight.
        var bg = UIBackgroundConfiguration.listCell()
        bg.backgroundColor = (state.isHighlighted || state.isSelected) ? .tertiarySystemFill : .clear
        bg.cornerRadius = 16
        bg.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
        backgroundConfiguration = bg
    }

    private let shimmer = CAGradientLayer()
    func setWorking(_ on: Bool) {
        preview.textColor = on ? .label : .secondaryLabel
        if on {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.4; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            preview.layer.add(a, forKey: "pulse")
        } else {
            preview.layer.removeAnimation(forKey: "pulse")
        }
    }

    /// Press-down squish on the avatar.
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.avatar.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
            }
        }
    }
}

final class ReasonsListViewController: UIViewController, UICollectionViewDelegate {
    private let app = AppState.shared!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var reasons: [String: Reason] = [:]
    private var order: [String] = []
    private var seen: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "seen") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "seen") }
    }
    private var refreshTask: Task<Void, Never>?
    private var hasAnimatedIn = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reasons"
        navigationController?.navigationBar.prefersLargeTitles = true
        view.backgroundColor = Theme.background
        observeLive()

        var cfg = UICollectionLayoutListConfiguration(appearance: .plain)
        cfg.showsSeparators = false
        cfg.backgroundColor = Theme.background
        cfg.trailingSwipeActionsConfigurationProvider = nil
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: cfg))
        collectionView.delegate = self
        view.addSubview(collectionView)
        collectionView.pin(to: view)
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            Task { await self?.reload(); self?.collectionView.refreshControl?.endRefreshing() }
        })

        let reg = UICollectionView.CellRegistration<ReasonCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createReason() })
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: profileButton)
        profileButton.addAction(UIAction { [weak self] _ in self?.showProfile() }, for: .touchUpInside)
        profileButton.configure(email: app.me?.serviceUserName)

        // Instant: last-known Reasons and previews from disk, no spinner, no splash.
        if !app.reasons.isEmpty {
            reasons = Dictionary(uniqueKeysWithValues: app.reasons.map { ($0.id, $0) })
            order = app.reasons.map(\.id)
            hasAnimatedIn = true
            sortByRecent()
            applySnapshot()
        }
        Task { await reload() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let ip = collectionView.indexPathsForSelectedItems?.first {
            if let tc = transitionCoordinator {
                tc.animate(alongsideTransition: { _ in self.collectionView.deselectItem(at: ip, animated: true) }) { ctx in
                    if ctx.isCancelled { self.collectionView.selectItem(at: ip, animated: false, scrollPosition: []) }
                }
            } else {
                collectionView.deselectItem(at: ip, animated: animated)
            }
        }
        reconfigureAll()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.refreshPreviews()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
    }

    private var observers: [NSObjectProtocol] = []
    private let profileButton = ProfileButton()
    /// Sessions currently running, by Reason (its conversation and the Sessions it started).
    private var runningSessions: [String: Set<String>] = [:]
    private var sessionReason: [String: String] = [:]

    private func refreshWorking(_ reasonId: String) async {
        guard let list = try? await app.api.sessions(reasonId: reasonId, first: 15) else { return }
        for s in list { sessionReason[s.sessionId] = reasonId }
        if let conv = reasons[reasonId]?.sessionId { sessionReason[conv] = reasonId }
        var running = Set(list.filter { $0.status == "running" }.map(\.sessionId))
        if let conv = reasons[reasonId]?.sessionId, LiveHub.shared.running.contains(conv) { running.insert(conv) }
        runningSessions[reasonId] = running
    }

    private func isWorking(_ reasonId: String) -> Bool { !(runningSessions[reasonId]?.isEmpty ?? true) }

    private func observeLive() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: LiveHub.resumed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.reload() } }
        })
        observers.append(nc.addObserver(forName: LiveHub.sessionEvent, object: nil, queue: .main) { [weak self] n in
            guard let e = n.object as? LiveHub.SessionEvent else { return }
            MainActor.assumeIsolated { self?.handle(e) }
        })
        observers.append(nc.addObserver(forName: LiveHub.viewsChanged, object: nil, queue: .main) { [weak self] n in
            let topics = n.userInfo?["topics"] as? [String] ?? []
            MainActor.assumeIsolated {
                if topics.contains("reasons") { Task { await self?.reload() } }
            }
        })
    }

    /// A Reason's conversation Session moved: refresh just that row.
    private func handle(_ e: LiveHub.SessionEvent) {
        let owner = sessionReason[e.sessionId] ?? reasons.values.first(where: { $0.sessionId == e.sessionId })?.id
        if let owner {
            if e.type == "turn.started" { runningSessions[owner, default: []].insert(e.sessionId); reconfigure(owner) }
            if e.type == "turn.finished" { runningSessions[owner]?.remove(e.sessionId); reconfigure(owner) }
        }
        guard let id = reasons.values.first(where: { $0.sessionId == e.sessionId })?.id else { return }
        if e.type == "message.created" || e.type == "turn.finished" {
            Task {
                _ = try? await app.store(.reason(id)).poll()
                reconfigure(id)
                sortByRecent()
            }
        }
        reconfigure(id)
    }


    private func configure(_ cell: ReasonCell, id: String) {
        guard let r = reasons[id] else { return }
        cell.avatar.configure(r.appearance)
        cell.name.text = r.name
        let store = app.store(.reason(id))
        let working = isWorking(id) || (r.sessionId.map { LiveHub.shared.running.contains($0) } ?? false)
        cell.setWorking(working)
        // Asleep after a few quiet hours, like the desktop's computer napping.
        let lastActive = store.lastVisible?.date ?? r.updatedAt.flatMap(ISODate.parse) ?? .distantPast
        cell.avatar.state = working ? .working : (Date().timeIntervalSince(lastActive) > 3 * 3600 ? .sleeping : .idle)
        if working {
            cell.preview.text = "Working…"
            cell.stamp.text = ""
            cell.badge.isHidden = true
        } else if let last = store.lastVisible {
            cell.preview.text = Markdown.plain(last.isMine ? "You: " + last.text : (last.text.isEmpty ? "Failed" : last.text))
            cell.stamp.text = last.date.map(ISODate.listStamp) ?? ""
            cell.badge.isHidden = last.isMine || seen[id] == last.id
        } else {
            cell.preview.text = store.loaded ? (r.tagline ?? "Say hello") : " "
            cell.stamp.text = ""
            cell.badge.isHidden = true
        }
    }

    private func reload() async {
        do {
            try await app.ensureConnected()
            profileButton.configure(email: app.me?.serviceUserName)
            let list = try await app.api.reasons()
            app.remember(reasons: list)
            reasons = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            if Set(order) != Set(list.map(\.id)) { order = list.map(\.id) }
            applySnapshot()
            await withTaskGroup(of: Void.self) { g in
                for r in list {
                    g.addTask { @MainActor in
                        let st = self.app.store(.reason(r.id))
                        if st.loaded { _ = try? await st.poll() } else { try? await st.loadAll() }
                        await self.refreshWorking(r.id)
                        self.reconfigure(r.id)
                    }
                }
            }
            sortByRecent()
        } catch {
            let a = UIAlertController(title: "Couldn't load Reasons", message: error.localizedDescription, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        }
    }

    private func refreshPreviews() async {
        for id in order { _ = try? await app.store(.reason(id)).poll() }
        reconfigureAll()
        sortByRecent()
    }

    private func sortByRecent() {
        let main = order.first { reasons[$0]?.main == true }
        let sorted = order.sorted { a, b in
            if a == main { return true }
            if b == main { return false }
            let da = app.store(.reason(a)).lastVisible?.date ?? .distantPast
            let db = app.store(.reason(b)).lastVisible?.date ?? .distantPast
            return da > db
        }
        guard sorted != order else { return }
        order = sorted
        applySnapshot()
    }

    private func applySnapshot() {
        var s = NSDiffableDataSourceSnapshot<Int, String>()
        s.appendSections([0])
        s.appendItems(order)
        dataSource.apply(s, animatingDifferences: hasAnimatedIn)
        if !hasAnimatedIn && !order.isEmpty { hasAnimatedIn = true; cascadeIn() }
    }

    /// First load: rows drop in with a staggered spring.
    private func cascadeIn() {
        collectionView.layoutIfNeeded()
        for (i, cell) in collectionView.visibleCells.sorted(by: { $0.frame.minY < $1.frame.minY }).enumerated() {
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: 24)
            UIView.animate(withDuration: 0.7, delay: 0.04 * Double(i), usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                cell.alpha = 1
                cell.transform = .identity
            }
        }
    }

    private func reconfigure(_ id: String) {
        var s = dataSource.snapshot()
        guard s.itemIdentifiers.contains(id) else { return }
        s.reconfigureItems([id])
        dataSource.apply(s, animatingDifferences: false)
    }

    private func reconfigureAll() {
        var s = dataSource.snapshot()
        s.reconfigureItems(s.itemIdentifiers)
        dataSource.apply(s, animatingDifferences: false)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: ip), let r = reasons[id] else { return }
        if let last = app.store(.reason(id)).lastVisible { var s = seen; s[id] = last.id; seen = s }
        navigationController?.pushViewController(ChatViewController(mode: .reason(r)), animated: true)
    }

    private func showProfile() {
        let nav = UINavigationController(rootViewController: ProfileViewController())
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(nav, animated: true)
    }

    private func createReason() {
        let vc = NewReasonViewController()
        vc.onCreated = { [weak self] r in
            guard let self else { return }
            self.reasons[r.id] = r
            self.order.insert(r.id, at: min(1, self.order.count))
            self.app.remember(reasons: self.order.compactMap { self.reasons[$0] })
            self.applySnapshot()
            self.dismiss(animated: true) {
                self.navigationController?.pushViewController(ChatViewController(mode: .reason(r)), animated: true)
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(nav, animated: true)
    }

}
