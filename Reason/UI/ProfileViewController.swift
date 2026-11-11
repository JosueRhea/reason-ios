import UIKit

/// Circle with the account's initials on a colour derived from the email.
final class ProfileButton: UIControl {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 17
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        addSubview(label)
        label.pin(to: self)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Profile"
        configure(email: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(email: String?) {
        label.text = Self.initials(email)
    }

    static func initials(_ email: String?) -> String {
        guard let e = email, let first = e.first else { return "·" }
        return String(first).uppercased()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }
}

/// Account, limits, subscriptions, activity, usage, GitHub and the API key.
final class ProfileViewController: UIViewController {
    private let app = AppState.shared!
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let limitCard = Card(title: "This week")
    private let subsCard = Card(title: "Subscriptions")
    private let activityCard = Card(title: "Activity")
    private let usageCard = Card(title: "Usage by model")
    private let githubCard = Card(title: "GitHub")
    private let keyCard = Card(title: "API key")
    private let permsCard = Card(title: "Permissions")
    private let roleChip = Chip(text: "…", symbol: "person.fill")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.pin(to: view)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        stack.addArrangedSubview(header())
        for c in [limitCard, subsCard, activityCard, usageCard, githubCard, keyCard, permsCard] { c.setLoading(); stack.addArrangedSubview(c) }
        fillPermissions()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fillPermissions() }   // back from Settings: show the new state
        }
        NotificationCenter.default.addObserver(forName: Push.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fillPermissions() }
        }
        stack.addArrangedSubview(signOutButton())
        for (i, v) in stack.arrangedSubviews.enumerated() {
            v.alpha = 0; v.transform = CGAffineTransform(translationX: 0, y: 16)
            UIView.animate(withDuration: 0.6, delay: 0.04 * Double(i), usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                v.alpha = 1; v.transform = .identity
            }
        }
        load()
    }

    private func header() -> UIView {
        let email = app.me?.serviceUserName
        let avatar = UIView()
        avatar.backgroundColor = .tertiarySystemFill
        avatar.layer.cornerRadius = 38
        let initial = UILabel()
        initial.text = ProfileButton.initials(email)
        initial.font = .systemFont(ofSize: 30, weight: .semibold)
        initial.textColor = .label
        initial.textAlignment = .center
        avatar.addSubview(initial)
        initial.pin(to: avatar)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 76), avatar.heightAnchor.constraint(equalToConstant: 76)])

        let name = UILabel()
        name.text = email ?? "Your account"
        name.font = .systemFont(ofSize: 21, weight: .semibold)
        let org = UILabel()
        org.text = app.me?.organizationName.map { "\($0) workspace" }
        org.font = .systemFont(ofSize: 14)
        org.textColor = .secondaryLabel
        let chips = UIStackView(arrangedSubviews: [roleChip])
        chips.spacing = 6
        let v = UIStackView(arrangedSubviews: [avatar, name, org, chips])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 5
        v.setCustomSpacing(12, after: avatar)
        v.setCustomSpacing(10, after: org)
        v.isLayoutMarginsRelativeArrangement = true
        v.layoutMargins = UIEdgeInsets(top: 6, left: 0, bottom: 2, right: 0)
        return v
    }

    private func signOutButton() -> UIView {
        let b = UIButton(type: .system)
        var c = UIButton.Configuration.plain()
        c.title = "Sign Out"
        c.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
        c.imagePadding = 8
        c.baseForegroundColor = .systemRed
        b.configuration = c
        b.addAction(UIAction { [weak self] _ in
            let a = UIAlertController(title: "Sign out?", message: "Your API key is removed from this device.", preferredStyle: .actionSheet)
            a.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { _ in
                if let key = Keychain.load() { Push.shared.unregister(key: key) }
                Keychain.delete()
                self?.dismiss(animated: true) {
                    (UIApplication.shared.connectedScenes.first?.delegate as? SceneDelegate)?.showOnboarding()
                }
            })
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self?.present(a, animated: true)
        }, for: .touchUpInside)
        return b
    }

    // MARK: Data

    private func load() {
        let api = app.api
        Task { if let r = try? await api.json("roles/me") { setRole(r) } }
        Task { fillLimit(try? await api.json("usage/quota")) }
        Task { await fillSubscriptions() }
        Task { fillActivity(try? await api.json("consumption/daily")) }
        Task { fillUsage(try? await api.json("usage/summary")) }
        Task { fillGitHub(try? await api.json("git-connections")) }
        Task { fillKey(try? await api.json("self/readiness", org: false)) }
    }

    private func setRole(_ r: [String: Any]) {
        let role = (r["membership_role"] as? String ?? "member").capitalized
        let replacement = Chip(text: role, symbol: role == "Owner" ? "crown.fill" : "person.fill")
        if let parent = roleChip.superview as? UIStackView {
            parent.insertArrangedSubview(replacement, at: 0)
            roleChip.removeFromSuperview()
        }
    }

    private func fillLimit(_ q: [String: Any]?) {
        guard let q, let used = q["used_percent"] as? Double else { limitCard.setRows([note("Not available")]); return }
        let reset = (q["resets_at"] as? String).flatMap(ISODate.parse)
        let ring = RingView(fraction: used / 100, tint: used > 85 ? .systemOrange : .label)
        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([ring.widthAnchor.constraint(equalToConstant: 84), ring.heightAnchor.constraint(equalToConstant: 84)])
        let big = UILabel()
        big.text = "\(Int(used))% used"
        big.font = .systemFont(ofSize: 22, weight: .semibold)
        let sub = UILabel()
        sub.text = [q["label"] as? String, reset.map { "Resets " + Self.relativeDay($0) }].compactMap { $0 }.joined(separator: " · ")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabel
        sub.numberOfLines = 2
        let texts = UIStackView(arrangedSubviews: [big, sub])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [ring, texts])
        row.spacing = 18
        row.alignment = .center
        limitCard.setRows([row])
    }

    private func fillSubscriptions() async {
        guard let creds = try? await app.api.json("provider-credentials"), let items = creds["items"] as? [[String: Any]] else {
            subsCard.setRows([note("Not available")]); return
        }
        if items.isEmpty { subsCard.setRows([note("No connected subscriptions")]); return }
        var rows: [UIView] = []
        var slot = 0
        for it in items.sorted(by: { ($0["provider_id"] as? String ?? "") > ($1["provider_id"] as? String ?? "") }) {
            let provider = it["provider_id"] as? String ?? ""
            let key = it["account_key"] as? String ?? ""
            var label = it["account_label"] as? String ?? "Account"
            if label.hasPrefix("Slot ") { slot += 1; label = "Account \(slot + 1)" }
            let usage = try? await app.api.json("provider-credentials/\(provider)/accounts/\(key)/usage")
            let window = (usage?["windows"] as? [[String: Any]])?.first
            let remaining = window?["remaining_percent"] as? Double
            let reset = (window?["resets_at"] as? String).flatMap(ISODate.parse)
            rows.append(SubscriptionRow(icon: BrandIcon.forProvider(provider), title: (provider == "anthropic" ? "Claude" : provider == "openai-codex" ? "ChatGPT" : provider.capitalized) + " · " + label,
                                        email: it["account_email"] as? String, remaining: remaining.map { $0 / 100 },
                                        detail: remaining != nil ? "\(Int(remaining!))% left\(reset.map { " · resets " + Self.relativeDay($0) } ?? "")" : "Usage not reported"))
        }
        subsCard.setRows(rows)
    }

    private func fillActivity(_ d: [String: Any]?) {
        guard let d, let days = d["daily"] as? [[String: Any]] else { activityCard.setRows([note("Not available")]); return }
        // Fill gaps so the chart shows the last 14 calendar days.
        var minutes: [String: Double] = [:]
        for day in days { if let k = day["date"] as? String { minutes[k] = day["sandbox_minutes"] as? Double ?? 0 } }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let series: [(String, Double)] = (0..<14).reversed().map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let k = f.string(from: date)
            return (k, minutes[k] ?? 0)
        }
        let total = (d["total"] as? [String: Any])?["sandbox_minutes"] as? Double ?? series.reduce(0) { $0 + $1.1 }
        let title = UILabel()
        title.text = "\(Int(total)) min"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let sub = UILabel()
        sub.text = "Computer time in the last 30 days"
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabel
        let chart = BarChart(values: series.map(\.1), labels: series.map { String($0.0.suffix(2)) })
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let v = UIStackView(arrangedSubviews: [title, sub, chart])
        v.axis = .vertical
        v.spacing = 2
        v.setCustomSpacing(14, after: sub)
        activityCard.setRows([v])
    }

    private func fillUsage(_ s: [String: Any]?) {
        guard let models = s?["models"] as? [[String: Any]], !models.isEmpty else { usageCard.setRows([note("No usage yet")]); return }
        let sorted = models.sorted { ($0["total_tokens"] as? Double ?? 0) > ($1["total_tokens"] as? Double ?? 0) }
        let maxTokens = sorted.first?["total_tokens"] as? Double ?? 1
        usageCard.setRows(sorted.prefix(6).map { m in
            let name = m["model"] as? String ?? "?"
            let tokens = m["total_tokens"] as? Double ?? 0
            let runs = (m["requests"] as? Int) ?? Int(m["requests"] as? Double ?? 0)
            let own = (m["billing"] as? String) == "own_key"
            return UsageRow(icon: BrandIcon.forModel(name), title: Self.prettyModel(name),
                            detail: "\(runs) runs · \(ReasonInfoViewController.compact(Int(tokens))) tokens\(own ? " · your plan" : "")",
                            fraction: tokens / max(1, maxTokens))
        })
    }

    private func fillGitHub(_ g: [String: Any]?) {
        guard let items = g?["items"] as? [[String: Any]], !items.isEmpty else { githubCard.setRows([note("Not connected")]); return }
        githubCard.setRows(items.map { it in
            let login = it["account_login"] as? String ?? "?"
            let type = (it["account_type"] as? String ?? "").lowercased() == "organization" ? "Organization" : "User"
            let grant = (it["grant"] as? String) == "personal" ? "Personal" : "Team"
            return InfoRow(symbol: type == "Organization" ? "building.2" : "person", title: login,
                           subtitle: "\(type) · \(grant)", trailing: nil, dot: .systemGreen)
        })
    }

    private func fillKey(_ r: [String: Any]?) {
        let scopes = ((r?["access"] as? [String: Any])?["granted_scopes"] as? [String]) ?? []
        let role = (r?["access"] as? [String: Any])?["workspace_role"] as? String
        let key = app.api.apiKey
        let masked = key.count > 8 ? String(key.prefix(4)) + "••••" + String(key.suffix(4)) : "••••"
        let rows: [UIView] = [
            InfoRow(symbol: "key", title: masked, subtitle: "Stored in the Keychain on this device", trailing: nil, dot: nil),
            InfoRow(symbol: "checkmark.shield", title: "\(scopes.count) scopes", subtitle: scopes.prefix(6).joined(separator: ", ") + (scopes.count > 6 ? "…" : ""),
                    trailing: role?.capitalized, dot: nil),
        ]
        keyCard.setRows(rows)
    }

    private func fillPermissions() {
        let rows: [UIView] = [(Permissions.Kind.microphone, "mic", "Microphone", "Dictation"),
                              (.camera, "camera", "Camera", "Photos and videos you take to attach")].map { kind, symbol, title, use in
            let st = Permissions.status(kind)
            let (trailing, dot): (String, UIColor) = st == .granted ? ("On", .systemGreen) : st == .denied ? ("Off · Fix", .systemOrange) : ("Not asked", .systemGray3)
            let row = InfoRow(symbol: symbol, title: title, subtitle: use, trailing: trailing, dot: dot)
            row.addAction(UIAction { [weak self] _ in
                switch Permissions.status(kind) {
                case .notAsked: Task { _ = await Permissions.request(kind); self?.fillPermissions() }
                default: Permissions.openSettings()
                }
            }, for: .touchUpInside)
            return row
        }
        let push = Push.shared.status
        let (pTrailing, pDot): (String, UIColor) = push == .on ? ("On", .systemGreen) : push == .off ? ("Off · Fix", .systemOrange) : ("Not asked", .systemGray3)
        let pushRow = InfoRow(symbol: "bell", title: "Notifications", subtitle: "Replies and questions from your Reasons", trailing: pTrailing, dot: pDot)
        pushRow.addAction(UIAction { [weak self] _ in
            Task { _ = await Push.shared.ensure(from: self); self?.fillPermissions() }
        }, for: .touchUpInside)
        var extra: [UIView] = [pushRow]
        if push == .on {
            let test = UIButton(type: .system)
            var tc = UIButton.Configuration.plain()
            tc.title = "Send a test notification"
            tc.image = UIImage(systemName: "bell.badge")
            tc.imagePadding = 8
            tc.baseForegroundColor = .label
            test.configuration = tc
            test.contentHorizontalAlignment = .leading
            test.addAction(UIAction { [weak self, weak test] _ in
                test?.configuration?.showsActivityIndicator = true
                Task {
                    do {
                        try await Push.shared.sendTest()
                        test?.configuration?.showsActivityIndicator = false
                        test?.configuration?.title = "Sent. Lock your phone to see it"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } catch {
                        test?.configuration?.showsActivityIndicator = false
                        let a = UIAlertController(title: "Couldn't send", message: (error as? APIError)?.message ?? error.localizedDescription, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(a, animated: true)
                    }
                }
            }, for: .touchUpInside)
            extra.append(test)
        }
        let open = UIButton(type: .system)
        var c = UIButton.Configuration.plain()
        c.title = "Open Settings"
        c.image = UIImage(systemName: "arrow.up.right")
        c.imagePlacement = .trailing
        c.imagePadding = 4
        c.baseForegroundColor = .label
        open.configuration = c
        open.contentHorizontalAlignment = .leading
        open.addAction(UIAction { _ in Permissions.openSettings() }, for: .touchUpInside)
        permsCard.setRows(extra + rows + [open])
    }

    private func note(_ t: String) -> UIView {
        let l = UILabel(); l.text = t; l.font = .systemFont(ofSize: 15); l.textColor = .secondaryLabel; return l
    }

    static func relativeDay(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func prettyModel(_ id: String) -> String {
        if let m = AppState.shared.models.first(where: { $0.id.hasSuffix(id) || $0.id == id }) { return m.displayName }
        let raw = id.replacingOccurrences(of: #"(?<=\d)-(?=\d)"#, with: ".", options: .regularExpression)
        return raw.replacingOccurrences(of: "-", with: " ").capitalized.replacingOccurrences(of: "Gpt", with: "GPT")
    }
}

// MARK: - Pieces

/// Circular progress that sweeps in on appear.
final class RingView: UIView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let fraction: CGFloat

    init(fraction: Double, tint: UIColor) {
        self.fraction = CGFloat(max(0, min(1, fraction)))
        super.init(frame: .zero)
        for l in [track, fill] {
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 9
            l.lineCap = .round
            layer.addSublayer(l)
        }
        track.strokeColor = UIColor.tertiarySystemFill.cgColor
        fill.strokeColor = tint.cgColor
        fill.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let p = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 5,
                             startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        track.frame = bounds; fill.frame = bounds
        track.path = p; fill.path = p
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, fill.strokeEnd == 0 else { return }
        let a = CASpringAnimation(keyPath: "strokeEnd")
        a.fromValue = 0; a.toValue = fraction
        a.damping = 14; a.stiffness = 60
        a.duration = a.settlingDuration
        a.beginTime = CACurrentMediaTime() + 0.2
        a.fillMode = .backwards
        fill.strokeEnd = fraction
        fill.add(a, forKey: "sweep")
    }
}

/// Simple bar chart; bars grow from the baseline with a stagger.
final class BarChart: UIView {
    private let values: [Double]
    private let labels: [String]
    private var bars: [CALayer] = []
    private var labelViews: [UILabel] = []
    private var animated = false

    init(values: [Double], labels: [String]) {
        self.values = values
        self.labels = labels
        super.init(frame: .zero)
        for (i, _) in values.enumerated() {
            let b = CALayer()
            b.backgroundColor = UIColor.label.cgColor
            b.cornerRadius = 3
            b.cornerCurve = .continuous
            layer.addSublayer(b)
            bars.append(b)
            let l = UILabel()
            l.text = i % 2 == 1 ? labels[i] : ""
            l.font = .systemFont(ofSize: 9)
            l.textColor = .tertiaryLabel
            l.textAlignment = .center
            addSubview(l)
            labelViews.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let n = CGFloat(max(1, values.count))
        let gap: CGFloat = 5
        let w = (bounds.width - gap * (n - 1)) / n
        let chartH = bounds.height - 14
        let maxV = max(1, values.max() ?? 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            let h = max(3, chartH * CGFloat(values[i] / maxV))
            let x = CGFloat(i) * (w + gap)
            b.anchorPoint = CGPoint(x: 0.5, y: 1)
            b.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            b.position = CGPoint(x: x + w / 2, y: chartH)
            b.opacity = values[i] > 0 ? 1 : 0.15
            labelViews[i].frame = CGRect(x: x - 4, y: chartH + 2, width: w + 8, height: 12)
        }
        CATransaction.commit()
        if !animated, window != nil { grow() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !animated, bounds.width > 0 { grow() }
    }

    private func grow() {
        animated = true
        for (i, b) in bars.enumerated() {
            let a = CASpringAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.02; a.toValue = 1
            a.damping = 12; a.stiffness = 140
            a.duration = a.settlingDuration
            a.beginTime = CACurrentMediaTime() + 0.15 + 0.03 * Double(i)
            a.fillMode = .backwards
            b.add(a, forKey: "grow")
        }
    }
}

final class SubscriptionRow: UIView {
    init(icon: BrandIcon, title: String, email: String?, remaining: Double?, detail: String) {
        super.init(frame: .zero)
        let iv = UIImageView(image: icon.image(size: 22))
        iv.tintColor = .label
        iv.contentMode = .center
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let t = UILabel(); t.text = title; t.font = .systemFont(ofSize: 15, weight: .medium)
        let e = UILabel(); e.text = email; e.font = .systemFont(ofSize: 12); e.textColor = .secondaryLabel; e.isHidden = email == nil
        let d = UILabel(); d.text = detail; d.font = .systemFont(ofSize: 12); d.textColor = .secondaryLabel
        var parts: [UIView] = [t, e]
        if let remaining {
            let meter = Meter(fraction: remaining, label: "")
            meter.tint = remaining < 0.2 ? .systemOrange : .label
            parts.append(meter)
        }
        parts.append(d)
        let texts = UIStackView(arrangedSubviews: parts)
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [iv, texts])
        row.spacing = 12
        row.alignment = .top
        addSubview(row)
        row.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class UsageRow: UIView {
    init(icon: BrandIcon, title: String, detail: String, fraction: Double) {
        super.init(frame: .zero)
        let iv = UIImageView(image: icon.image(size: 20))
        iv.tintColor = .label
        iv.contentMode = .center
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let t = UILabel(); t.text = title; t.font = .systemFont(ofSize: 15, weight: .medium)
        let d = UILabel(); d.text = detail; d.font = .systemFont(ofSize: 12); d.textColor = .secondaryLabel
        let bar = Meter(fraction: fraction, label: "")
        bar.tint = .label
        let texts = UIStackView(arrangedSubviews: [t, d, bar])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [iv, texts])
        row.spacing = 12
        row.alignment = .top
        addSubview(row)
        row.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}
