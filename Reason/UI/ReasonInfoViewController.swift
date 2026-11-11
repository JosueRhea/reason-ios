import UIKit

/// The desktop app's right-hand panel as a sheet: the Reason, its conversation's numbers,
/// computers, Sessions and this week's images.
final class ReasonInfoViewController: UIViewController {
    private let reason: Reason
    private let app = AppState.shared!
    var onOpenSession: ((SessionSummary) -> Void)?
    var onOpenImage: ((Markdown.ImageRef, UIImageView) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let statsCard = Card(title: "Conversation")
    private let computersCard = Card(title: "Computers")
    private let sessionsCard = Card(title: "Sessions")
    private let galleryCard = Card(title: "This week")
    private var sessions: [SessionSummary] = []
    private var showAllSessions = false

    init(reason: Reason) {
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.pin(to: view)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        stack.addArrangedSubview(header())
        for c in [statsCard, computersCard, sessionsCard, galleryCard] {
            c.setLoading()
            stack.addArrangedSubview(c)
        }
        buildGallery()
        cascadeIn()
        load()
    }

    private func header() -> UIView {
        let avatar = AvatarView()
        avatar.configure(reason.appearance)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 64), avatar.heightAnchor.constraint(equalToConstant: 64)])
        let name = UILabel()
        name.text = reason.name
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let tag = UILabel()
        tag.text = reason.tagline ?? (reason.main == true ? "Your main Reason" : nil)
        tag.font = .systemFont(ofSize: 14)
        tag.textColor = .secondaryLabel
        tag.numberOfLines = 0
        tag.textAlignment = .center
        tag.isHidden = tag.text == nil

        let chips = UIStackView()
        chips.spacing = 6
        if reason.main == true { chips.addArrangedSubview(Chip(text: "Main", symbol: "star.fill")) }
        if let model = reason.defaultModel { chips.addArrangedSubview(Chip(text: model.split(separator: "/").last.map(String.init) ?? model, symbol: "cpu")) }
        let n = app.store(.reason(reason.id)).visibleItems.count
        chips.addArrangedSubview(Chip(text: "\(n) message\(n == 1 ? "" : "s")", symbol: "bubble.left.and.bubble.right"))

        let v = UIStackView(arrangedSubviews: [avatar, name, tag, chips])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 6
        v.setCustomSpacing(10, after: avatar)
        v.setCustomSpacing(12, after: tag)
        v.isLayoutMarginsRelativeArrangement = true
        v.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 4, right: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { avatar.bounce() }
        return v
    }

    private func cascadeIn() {
        for (i, v) in stack.arrangedSubviews.enumerated() {
            v.alpha = 0
            v.transform = CGAffineTransform(translationX: 0, y: 18)
            UIView.animate(withDuration: 0.6, delay: 0.05 + 0.05 * Double(i), usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                v.alpha = 1; v.transform = .identity
            }
        }
    }

    // MARK: Data

    private func load() {
        Task {
            async let conv: SessionSummary? = reason.sessionId == nil ? nil : try? app.api.session(reason.sessionId!)
            async let devs = try? app.api.devices()
            async let sess = try? app.api.sessions(reasonId: reason.id, first: 30)
            let (c, d, s) = await (conv, devs, sess)
            fillStats(c)
            fillComputers(d ?? [])
            sessions = s ?? []
            fillSessions()
        }
    }

    private func fillStats(_ s: SessionSummary?) {
        guard let s else { statsCard.setRows([placeholder("No conversation yet")]); return }
        let model = app.models.first { $0.id == s.model }?.displayName ?? s.model?.split(separator: "/").last.map(String.init) ?? "—"
        let effort = s.reasoningEffort.map(EffortSlider.title) ?? "Auto"
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 14
        let row1 = UIStackView(arrangedSubviews: [Stat(title: "Model", value: model, sub: effort), Stat(title: "Status", value: Self.statusText(s), sub: s.status == "running" ? "Working now" : "Idle")])
        let row2 = UIStackView(arrangedSubviews: [
            Stat(title: "Cost", value: s.costUsd.map { String(format: "$%.2f", $0) } ?? "—", sub: "This conversation"),
            Stat(title: "Tokens", value: Self.compact(s.usage?.totalTokens), sub: "\(Self.compact(s.usage?.inputTokens)) in · \(Self.compact(s.usage?.outputTokens)) out"),
        ])
        for r in [row1, row2] { r.distribution = .fillEqually; r.spacing = 12; grid.addArrangedSubview(r) }

        if let pct = s.context?.percent, let window = s.context?.window {
            let meter = Meter(fraction: pct / 100, label: "Context  \(Int(pct))% of \(Self.compact(window))")
            grid.addArrangedSubview(meter)
        }
        statsCard.setRows([grid], padded: true)
    }

    private func fillComputers(_ devices: [DevicesPage.Device]) {
        var rows: [UIView] = [InfoRow(symbol: "cloud", title: "Reason cloud computer", subtitle: "Wakes when a Session needs it", trailing: nil, dot: .systemGray3)]
        for d in devices {
            let online = d.status == "active"
            let sub = [d.os == "darwin" ? "macOS" : d.os?.capitalized, d.kind == "headless" ? "Runtime" : d.kind?.capitalized].compactMap { $0 }.joined(separator: " · ")
            rows.append(InfoRow(symbol: d.os == "darwin" ? "laptopcomputer" : "server.rack", title: d.displayName,
                                subtitle: sub, trailing: online ? "Ready" : "Offline", dot: online ? .systemGreen : .systemGray3))
        }
        computersCard.setRows(rows)
    }

    private func fillSessions() {
        guard !sessions.isEmpty else { sessionsCard.setRows([placeholder("No sessions yet")]); return }
        let shown = showAllSessions ? sessions : Array(sessions.prefix(6))
        var rows: [UIView] = shown.map { s in
            let date = (s.updatedAt ?? s.createdAt).flatMap(ISODate.parse)
            let sub = [s.repo, s.costUsd.map { String(format: "$%.2f", $0) }].compactMap { $0 }.joined(separator: " · ")
            let row = InfoRow(symbol: Self.symbol(for: s), title: s.title ?? "Untitled session", subtitle: sub.isEmpty ? nil : sub,
                              trailing: date.map(ISODate.ago), dot: nil, tint: Self.tint(for: s), spinning: s.status == "running")
            row.addAction(UIAction { [weak self] _ in self?.onOpenSession?(s) }, for: .touchUpInside)
            return row
        }
        if sessions.count > 6 && !showAllSessions {
            let more = UIButton(type: .system)
            var c = UIButton.Configuration.plain()
            c.title = "Show \(sessions.count - 6) more"
            c.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            c.imagePlacement = .leading
            c.imagePadding = 6
            c.baseForegroundColor = .secondaryLabel
            more.configuration = c
            more.contentHorizontalAlignment = .leading
            more.addAction(UIAction { [weak self] _ in
                self?.showAllSessions = true
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
                    self?.fillSessions()
                    self?.view.layoutIfNeeded()
                }
            }, for: .touchUpInside)
            rows.append(more)
        }
        sessionsCard.setRows(rows)
    }

    /// Images the Reason posted in its replies over the last week, newest first.
    private func buildGallery() {
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var refs: [(Markdown.ImageRef, Date)] = []
        var seen = Set<URL>()
        for item in app.store(.reason(reason.id)).items.reversed() where !item.isMine {
            guard let d = item.date, d > weekAgo else { continue }
            for r in Markdown.extractImages(item.text).1 where !seen.contains(r.url) {
                seen.insert(r.url); refs.append((r, d))
            }
        }
        guard !refs.isEmpty else { galleryCard.isHidden = true; return }
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor, constant: -14),
            row.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
            strip.heightAnchor.constraint(equalToConstant: 150),
        ])
        for (r, d) in refs.prefix(20) {
            let tile = GalleryTile(ref: r, date: d)
            tile.onTap = { [weak self] v in self?.onOpenImage?(r, v) }
            row.addArrangedSubview(tile)
        }
        galleryCard.setRows([strip], padded: false, inset: false)
        galleryCard.setTitle("This week  ·  \(refs.count)")
    }

    private func placeholder(_ t: String) -> UIView {
        let l = UILabel()
        l.text = t
        l.font = .systemFont(ofSize: 15)
        l.textColor = .secondaryLabel
        return l
    }

    static func statusText(_ s: SessionSummary) -> String {
        switch s.status {
        case "running": return "Working"
        case "exit": return s.outcome == "failure" ? "Failed" : (s.outcome == "action_required" ? "Needs you" : "Finished")
        case "error": return "Error"
        case "suspended": return "Paused"
        default: return s.status?.capitalized ?? "—"
        }
    }

    static func compact(_ n: Int?) -> String {
        guard let n else { return "—" }
        switch n {
        case 1_000_000...: return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: n >= 10_000 ? "%.0fK" : "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    private static func symbol(for s: SessionSummary) -> String {
        switch (s.status, s.outcome) {
        case ("running", _): return "circle.dotted"
        case (_, "success"): return "checkmark.circle"
        case (_, "failure"), ("error", _): return "xmark.circle"
        case (_, "action_required"): return "exclamationmark.circle"
        default: return "bubble.left"
        }
    }

    private static func tint(for s: SessionSummary) -> UIColor {
        switch (s.status, s.outcome) {
        case ("running", _): return .systemBlue
        case (_, "success"): return .systemGreen
        case (_, "failure"), ("error", _): return .systemRed
        case (_, "action_required"): return .systemOrange
        default: return .secondaryLabel
        }
    }
}

// MARK: - Building blocks

/// White rounded card with a hairline border, like the desktop panel.
final class Card: UIView {
    private let titleLabel = UILabel()
    private let body = UIStackView()
    private let box = UIView()
    private var boxInsets: [NSLayoutConstraint] = []

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        titleLabel.textColor = .secondaryLabel
        box.backgroundColor = Theme.card
        box.layer.cornerRadius = 18
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1 / UIScreen.main.scale
        box.clipsToBounds = true
        body.axis = .vertical
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(body)
        let v = UIStackView(arrangedSubviews: [titleLabel, box])
        v.axis = .vertical
        v.spacing = 8
        addSubview(v)
        v.pin(to: self)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        boxInsets = [
            body.topAnchor.constraint(equalTo: box.topAnchor),
            body.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ]
        NSLayoutConstraint.activate(boxInsets)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (c: Card, _: UITraitCollection) in c.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStroke() { box.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }

    func setTitle(_ t: String) { titleLabel.text = t }

    func setLoading() {
        let s = UIActivityIndicatorView(style: .medium)
        s.startAnimating()
        setRows([s])
    }

    func setRows(_ rows: [UIView], padded: Bool = true, inset: Bool = true) {
        let fresh = body.arrangedSubviews.contains { $0 is UIActivityIndicatorView }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            let wrap = UIView()
            r.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(r)
            let h: CGFloat = inset ? 14 : 0
            let vpad: CGFloat = padded ? (rows.count == 1 ? 14 : 11) : 12
            NSLayoutConstraint.activate([
                r.topAnchor.constraint(equalTo: wrap.topAnchor, constant: vpad),
                r.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -vpad),
                r.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: h),
                r.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -h),
            ])
            body.addArrangedSubview(wrap)
            if i < rows.count - 1 {
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                let sepWrap = UIView()
                sepWrap.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.topAnchor.constraint(equalTo: sepWrap.topAnchor), sep.bottomAnchor.constraint(equalTo: sepWrap.bottomAnchor),
                    sep.leadingAnchor.constraint(equalTo: sepWrap.leadingAnchor, constant: 50), sep.trailingAnchor.constraint(equalTo: sepWrap.trailingAnchor),
                ])
                body.addArrangedSubview(sepWrap)
            }
            if fresh {
                wrap.alpha = 0
                UIView.animate(withDuration: 0.35, delay: 0.03 * Double(i)) { wrap.alpha = 1 }
            }
        }
    }
}

/// Icon · title/subtitle · trailing text, tappable.
final class InfoRow: UIControl {
    init(symbol: String, title: String, subtitle: String?, trailing: String?, dot: UIColor?, tint: UIColor = .secondaryLabel, spinning: Bool = false) {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        if spinning {
            let a = CABasicAnimation(keyPath: "transform.rotation")
            a.fromValue = 0; a.toValue = Double.pi * 2; a.duration = 2.2; a.repeatCount = .infinity
            icon.layer.add(a, forKey: "spin")
        }
        let t = UILabel()
        t.text = title
        t.font = .systemFont(ofSize: 15, weight: .regular)
        t.lineBreakMode = .byTruncatingTail
        let s = UILabel()
        s.text = subtitle
        s.font = .systemFont(ofSize: 12)
        s.textColor = .secondaryLabel
        s.isHidden = subtitle == nil
        let texts = UIStackView(arrangedSubviews: [t, s])
        texts.axis = .vertical
        texts.spacing = 1
        let right = UIStackView()
        right.spacing = 6
        right.alignment = .center
        if let dot {
            let d = UIView()
            d.backgroundColor = dot
            d.layer.cornerRadius = 3.5
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 7).isActive = true
            d.heightAnchor.constraint(equalToConstant: 7).isActive = true
            right.addArrangedSubview(d)
        }
        if let trailing {
            let l = UILabel()
            l.text = trailing
            l.font = .systemFont(ofSize: 13)
            l.textColor = .tertiaryLabel
            right.addArrangedSubview(l)
        }
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, texts, right])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.2) { self.alpha = self.isHighlighted ? 0.5 : 1 } }
    }
}

final class Stat: UIView {
    init(title: String, value: String, sub: String?) {
        super.init(frame: .zero)
        let t = UILabel()
        t.text = title.uppercased()
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .tertiaryLabel
        let v = UILabel()
        v.text = value
        v.font = .systemFont(ofSize: 19, weight: .semibold)
        v.adjustsFontSizeToFitWidth = true
        v.minimumScaleFactor = 0.6
        let s = UILabel()
        s.text = sub
        s.font = .systemFont(ofSize: 12)
        s.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [t, v, s])
        stack.axis = .vertical
        stack.spacing = 2
        addSubview(stack)
        stack.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Thin progress bar that fills with a spring when it appears.
final class Meter: UIView {
    private let fill = UIView()
    private let fraction: CGFloat
    private var widthC: NSLayoutConstraint!

    /// Bar colour override (e.g. warn when little is *left*).
    var tint: UIColor? { didSet { if let tint { fill.backgroundColor = tint } } }

    init(fraction: Double, label: String) {
        self.fraction = CGFloat(max(0.02, min(1, fraction)))
        super.init(frame: .zero)
        let l = UILabel()
        l.text = label
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        let track = UIView()
        track.backgroundColor = .tertiarySystemFill
        track.layer.cornerRadius = 3
        fill.backgroundColor = fraction > 0.8 ? .systemOrange : .label
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        widthC = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: 0.001)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            widthC,
            track.heightAnchor.constraint(equalToConstant: 6),
        ])
        l.isHidden = label.isEmpty
        let stack = UIStackView(arrangedSubviews: [l, track])
        stack.axis = .vertical
        stack.spacing = 6
        addSubview(stack)
        stack.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let track = fill.superview else { return }
        layoutIfNeeded()
        widthC.isActive = false
        widthC = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fraction)
        widthC.isActive = true
        UIView.animate(withDuration: 0.9, delay: 0.2, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { self.layoutIfNeeded() }
    }
}

final class Chip: UIView {
    init(text: String, symbol: String) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 11
        let i = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
        i.tintColor = .secondaryLabel
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabel
        let s = UIStackView(arrangedSubviews: [i, l])
        s.spacing = 4
        s.alignment = .center
        addSubview(s)
        s.pin(to: self, insets: UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 10))
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class GalleryTile: UIView {
    var onTap: ((UIImageView) -> Void)?
    private let image = RemoteImageView()

    init(ref: Markdown.ImageRef, date: Date) {
        super.init(frame: .zero)
        image.configure(ref, width: 160)
        image.layer.cornerRadius = 12
        // Fixed tile height regardless of aspect.
        image.constraints.forEach { if $0.firstAttribute == .height { $0.constant = 100 } }
        let t = UILabel()
        t.text = ref.alt.isEmpty ? "Image" : ref.alt
        t.font = .systemFont(ofSize: 13, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        let s = UILabel()
        s.text = ISODate.listStamp(date)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [image, t, s])
        stack.axis = .vertical
        stack.spacing = 3
        stack.setCustomSpacing(7, after: image)
        addSubview(stack)
        stack.pin(to: self)
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        image.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTap?(image)
    }
}
