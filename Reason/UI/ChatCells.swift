import UIKit

/// A tappable link pulled out of a message: a child Session, a PR, a preview or a plain link.
struct LinkChip: Hashable {
    enum Kind: Hashable { case session(String), pullRequest, preview, link }
    let kind: Kind
    let title: String
    let url: URL

    var symbol: String {
        switch kind {
        case .session: return "arrow.triangle.branch"
        case .pullRequest: return "arrow.triangle.pull"
        case .preview: return "safari"
        case .link: return "link"
        }
    }

    /// Finds Session, PR and preview links in markdown/plain text.
    private static var memo: [String: [LinkChip]] = [:]
    private static let re = try! NSRegularExpression(pattern: #"(?:\[([^\]]+)\]\()?(https?://[^\s)]+)\)?"#)

    /// Memoized: render() asks for every message's chips on each pass.
    static func extract(from text: String) -> [LinkChip] {
        if let hit = memo[text] { return hit }
        guard text.contains("http") else { return [] }
        let r = scan(text)
        if memo.count > 2000 { memo.removeAll() }
        memo[text] = r
        return r
    }

    private static func scan(_ text: String) -> [LinkChip] {
        var out: [LinkChip] = []
        var seen = Set<String>()
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
            let raw = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            guard let url = URL(string: raw), let host = url.host else { continue }
            let path = url.path
            var chip: LinkChip?
            if host.hasSuffix("reasonmachines.com"), path.hasPrefix("/agents/") {
                let parts = path.split(separator: "/")
                if parts.count >= 2 {
                    let sid = String(parts[1])
                    if parts.count >= 3, parts[2] == "preview" {
                        let port = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "port" }?.value
                        chip = LinkChip(kind: .preview, title: "Preview" + (port.map { " :\($0)" } ?? ""), url: url)
                    } else {
                        chip = LinkChip(kind: .session(sid), title: label ?? "Open session", url: url)
                    }
                }
            } else if host == "github.com", path.contains("/pull/") {
                let p = path.split(separator: "/")
                if p.count >= 4 { chip = LinkChip(kind: .pullRequest, title: "\(p[0])/\(p[1]) #\(p[3])", url: url) }
            }
            if let c = chip, !seen.contains(c.url.absoluteString) {
                seen.insert(c.url.absoluteString)
                out.append(c)
            }
        }
        return out
    }
}

enum ReportState: Hashable {
    case finished, failed, stopped, needsInput
    init(verb: String) {
        let v = verb.lowercased()
        if v.hasPrefix("fail") || v.hasPrefix("error") { self = .failed }
        else if v.hasPrefix("cancel") || v.hasPrefix("stop") || v.hasPrefix("was cancel") || v.hasPrefix("suspend") { self = .stopped }
        else if v.contains("input") || v.contains("blocked") || v.contains("waiting") { self = .needsInput }
        else { self = .finished }
    }
}

struct MessageModel: Hashable {
    enum Style: Hashable {
        case bubble
        case report(title: String, state: ReportState, sessionId: String?)   // "Session "X" finished" from a child Session
        case notice                                                 // system message
        case agentNote(from: String)                                // sent by another agent/app, collapsed
        case childEvent(verb: String, title: String, sessionId: String, status: String?)   // "Sent a message to ● Port reason-desk…"
    }
    let id: String
    var style: Style = .bubble
    var expanded = false
    var chips: [LinkChip] = []
    var text: String
    var mine: Bool
    var joinTop: Bool
    var joinBottom: Bool
    var failed: Bool        // reply failed, or our send didn't go through
    var header: String?     // "Message from reason-ios · hi@…"
    var footer: String?     // "GPT-6 Luna · High · 8:41 PM"
    var images: [Markdown.ImageRef]
    var topGap: CGFloat = 2
    var files: [AttachmentRef] = []
    var now: ActivityStep?  // running child: its current step
}

// MARK: - Message

final class MessageCell: UICollectionViewCell {
    /// Measured heights by (message, width): the list re-asks for the same rows many times while it
    /// settles (jump to bottom, redraws), and measuring a long reply means laying out all its text.
    private static var heights: [Int: CGFloat] = [:]

    override func preferredLayoutAttributesFitting(_ a: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        guard let m = model else { return super.preferredLayoutAttributesFitting(a) }
        if !m.mine { doc.widthHint = a.size.width - 2 * Self.theirsInset }
        var h = Hasher()
        h.combine(m)
        h.combine(a.size.width)
        let key = h.finalize()
        if let cached = Self.heights[key] {
            let out = a.copy() as! UICollectionViewLayoutAttributes
            out.size.height = cached
            return out
        }
        let r = super.preferredLayoutAttributesFitting(a)
        if Self.heights.count > 3000 { Self.heights.removeAll() }
        Self.heights[key] = r.size.height
        return r
    }

    /// Favicons can change a line's height; forget heights when they land.
    static func forgetHeights() { heights.removeAll() }
    static let reuse = "msg"
    static let outerInset: CGFloat = 14

    let column = UIStackView()
    let bubble = BubbleView()
    let label = UILabel()
    /// Agent replies: full markdown (code blocks, tables, quotes). Our bubbles keep the single label.
    let doc = MarkdownView()
    private let body = UIStackView()
    private let header = UILabel()
    private let footer = UILabel()
    private let errorBadge = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private var imageViews: [RemoteImageView] = []
    let chips = ChipsView()
    private(set) var model: MessageModel?
    private(set) var rendered: NSAttributedString?
    var onImageTap: ((RemoteImageView, Markdown.ImageRef) -> Void)?
    var onFileTap: ((FileCardView) -> Void)?
    var onLinkTap: ((URL) -> Void)?
    private var fileCards: [FileCardView] = []
    private lazy var linkTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:)))
        g.delegate = self
        return g
    }()

    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var leadingMin: NSLayoutConstraint!
    private var trailingMin: NSLayoutConstraint!
    private var topGap: NSLayoutConstraint!
    private var bubbleMax: NSLayoutConstraint!     // ours: a bubble at most 82% wide
    private var bubbleFull: NSLayoutConstraint!    // theirs: plain text across the row
    private var pad: [NSLayoutConstraint] = []     // text inset inside the bubble (zero for theirs)

    /// Agent text starts where activity rows and cards do.
    static let theirsInset: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(linkTap)
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(label)
        body.addArrangedSubview(doc)
        bubble.addSubview(body)
        pad = [
            body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ]
        NSLayoutConstraint.activate(pad)

        header.font = .systemFont(ofSize: 12, weight: .regular)
        header.textColor = .tertiaryLabel
        footer.font = .systemFont(ofSize: 11, weight: .regular)
        footer.textColor = .tertiaryLabel
        errorBadge.tintColor = .systemRed
        errorBadge.contentMode = .scaleAspectFit
        errorBadge.translatesAutoresizingMaskIntoConstraints = false
        errorBadge.widthAnchor.constraint(equalToConstant: 18).isActive = true
        errorBadge.heightAnchor.constraint(equalToConstant: 18).isActive = true

        column.axis = .vertical
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, bubble, chips, footer] { column.addArrangedSubview(v) }
        column.setCustomSpacing(5, after: header)
        contentView.addSubview(column)

        topGap = column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2)
        leading = column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.outerInset)
        trailing = column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.outerInset)
        leadingMin = column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 56)
        trailingMin = column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -40)
        NSLayoutConstraint.activate([
            topGap,
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        bubbleMax = bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82)
        bubbleFull = bubble.widthAnchor.constraint(equalTo: column.widthAnchor)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: MessageModel) {
        model = m
        let color = m.mine ? Theme.mineText : Theme.theirsText
        let link = m.mine ? Theme.mineText : UIColor.link
        if m.mine {
            let r = Markdown.render(m.text, color: color, linkColor: link)
            rendered = r
            label.attributedText = Favicons.decorate(r, font: Theme.bodyFont, tint: link)
            doc.configure([])
        } else {
            rendered = nil
            label.attributedText = nil
            let w = contentView.bounds.width > 0 ? contentView.bounds.width : (window?.bounds.width ?? UIScreen.main.bounds.width)
            doc.widthHint = w - 2 * Self.theirsInset
            doc.configure(MarkdownDoc.parse(m.text, color: color, linkColor: link), linkTint: link)
            doc.onLinkTap = { [weak self] url in self?.onLinkTap?(url) }
        }
        label.isHidden = !m.mine
        doc.isHidden = m.mine
        bubble.isHidden = m.text.isEmpty

        bubble.side = m.mine ? .right : .left
        bubble.joinTop = m.joinTop
        bubble.joinBottom = m.joinBottom
        // Only our messages are bubbles; the agent's are plain text, like a document.
        bubble.fillColor = m.mine ? Theme.mineBubble : .clear
        let inset: (top: CGFloat, side: CGFloat, bottom: CGFloat) = m.mine ? (9, 14, 10) : (0, 0, 0)
        pad[0].constant = inset.top; pad[1].constant = -inset.bottom
        pad[2].constant = inset.side; pad[3].constant = -inset.side

        column.alignment = m.mine ? .trailing : .leading
        NSLayoutConstraint.deactivate([leading, trailing, leadingMin, trailingMin, bubbleMax, bubbleFull])
        leading.constant = m.mine ? Self.outerInset : Self.theirsInset
        trailing.constant = m.mine ? -Self.outerInset : -Self.theirsInset
        NSLayoutConstraint.activate(m.mine ? [trailing, leadingMin, bubbleMax] : [leading, trailing, bubbleFull])
        // Back-to-back agent messages read as paragraphs, not stacked bubbles.
        topGap.constant = !m.mine && m.joinTop ? max(m.topGap, 12) : m.topGap

        header.text = m.header
        header.isHidden = m.header == nil
        footer.text = m.footer
        footer.textColor = m.failed ? .systemRed : .tertiaryLabel
        footer.isHidden = m.footer == nil

        configureImages(m.images + m.files.compactMap(\.imageRef))
        configureFiles(m.files.filter { !$0.isImage }, mine: m.mine)
        chips.configure(m.chips)
    }

    private func configureImages(_ refs: [Markdown.ImageRef]) {
        while imageViews.count < refs.count {
            let v = RemoteImageView()
            v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            imageViews.append(v)
        }
        for (i, v) in imageViews.enumerated() {
            if i < refs.count {
                if v.superview == nil { column.insertArrangedSubview(v, at: column.arrangedSubviews.firstIndex(of: chips)!) }
                v.isHidden = false
                v.configure(refs[i], width: 260)
            } else {
                v.isHidden = true
            }
        }
    }

    @objc private func imageTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view as? RemoteImageView, let ref = v.ref else { return }
        onImageTap?(v, ref)
    }

    @objc private func linkTapped(_ g: UITapGestureRecognizer) {
        guard let url = label.link(at: g.location(in: label)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onLinkTap?(url)
    }

    /// Only taps that land on a link are ours; everything else falls through to the cell.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === linkTap else { return super.gestureRecognizerShouldBegin(g) }
        return label.link(at: g.location(in: label)) != nil
    }

    private func configureFiles(_ refs: [AttachmentRef], mine: Bool) {
        guard refs != fileCards.map(\.ref) else { return }
        fileCards.forEach { $0.removeFromSuperview() }
        fileCards = refs.map { r in
            let card = FileCardView(r, mine: mine)
            card.addAction(UIAction { [weak self, weak card] _ in
                if let card { self?.onFileTap?(card) }
            }, for: .touchUpInside)
            return card
        }
        let at = column.arrangedSubviews.firstIndex(of: chips) ?? column.arrangedSubviews.count
        for (i, c) in fileCards.enumerated() { column.insertArrangedSubview(c, at: at + i) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        column.transform = .identity
        column.alpha = 1
        contentView.alpha = 1
        onImageTap = nil
        onFileTap = nil
        onLinkTap = nil
    }
}

// MARK: - Remote image thumbnail

final class RemoteImageView: UIImageView {
    private(set) var ref: Markdown.ImageRef?
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    private var task: Task<Void, Never>?
    private let shimmer = CAGradientLayer()

    convenience init() { self.init(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        backgroundColor = .secondarySystemFill
        isUserInteractionEnabled = true
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 260)
        height = heightAnchor.constraint(equalToConstant: 160)
        width.priority = .init(999); height.priority = .init(999)
        NSLayoutConstraint.activate([width, height])
        shimmer.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.25).cgColor, UIColor.clear.cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.5, 1]
        layer.addSublayer(shimmer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    }

    func configure(_ r: Markdown.ImageRef, width w: CGFloat) {
        guard ref != r else { return }
        ref = r
        accessibilityLabel = r.alt
        width.constant = w
        height.constant = (w * r.aspect).rounded()
        task?.cancel()
        let px = w * UIScreen.main.scale
        if let hit = ImageLoader.shared.cached(r.url, maxPixel: px) {
            image = hit
            stopShimmer()
            return
        }
        image = nil
        startShimmer()
        task = Task { [weak self] in
            let img = await ImageLoader.shared.load(r.url, maxPixel: px)
            guard let self, !Task.isCancelled, self.ref == r else { return }
            self.stopShimmer()
            UIView.transition(with: self, duration: 0.3, options: .transitionCrossDissolve) { self.image = img }
        }
    }

    private func startShimmer() {
        shimmer.isHidden = false
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = -bounds.width
        a.toValue = bounds.width
        a.duration = 1.2
        a.repeatCount = .infinity
        shimmer.add(a, forKey: "shimmer")
    }

    private func stopShimmer() {
        shimmer.removeAllAnimations()
        shimmer.isHidden = true
    }
}

// MARK: - Timestamp separator

final class StampCell: UICollectionViewCell {
    static let reuse = "stamp"
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        contentView.addSubview(label)
        label.pin(to: contentView, insets: UIEdgeInsets(top: 18, left: 0, bottom: 10, right: 0))
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Live turn: steps + streaming reply

struct LiveStep: Hashable {
    let id: String
    var icon: String
    var title: String
    var detail: String?
    var done: Bool
    var failed: Bool
}

final class LiveCell: UICollectionViewCell {
    static let reuse = "live"
    let bubble = BubbleView()
    private let stepsStack = UIStackView()
    private let summary = UILabel()
    private let textLabel = UILabel()
    private let dots = TypingDots()
    private let column = UIStackView()
    private var shownStepIds: [String] = []

    // Streaming reveal: the latest snapshot is laid out in full (layout never changes while it reveals),
    // and released a few words at a time. Each batch sweeps in left to right with a soft glow, so text
    // arrives in readable phrases rather than letter by letter.
    private var fullText: NSAttributedString?
    private var revealed = 0
    private var batches: [(range: NSRange, born: CFTimeInterval)] = []
    private var nextBatchAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private static let batchEvery: CFTimeInterval = 0.05
    private static let sweep: CFTimeInterval = 0.32

    override init(frame: CGRect) {
        super.init(frame: frame)
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.textColor = .secondaryLabel

        stepsStack.axis = .vertical
        stepsStack.spacing = 6

        // No bubble: streaming text reads exactly like the plain reply it turns into.
        bubble.side = .left
        bubble.fillColor = .clear
        textLabel.numberOfLines = 0
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        dots.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(textLabel)
        bubble.addSubview(dots)
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: bubble.topAnchor),
            textLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            textLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            dots.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 2),
            dots.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            bubble.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])

        column.axis = .vertical
        column.alignment = .fill        // full-width text, like the reply
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        [summary, stepsStack, bubble].forEach(column.addArrangedSubview)
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MessageCell.theirsInset),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MessageCell.theirsInset),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stepsStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.86),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(steps: [LiveStep], text: String?, summaryText: String?) {
        summary.text = summaryText
        summary.isHidden = summaryText == nil

        // Show only the latest few steps; older ones fold into the summary.
        let visible = Array(steps.suffix(4))
        let ids = visible.map(\.id)
        if ids != shownStepIds {
            let fresh = Set(ids).subtracting(shownStepIds)
            stepsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for s in visible {
                let row = StepRow()
                row.configure(s)
                stepsStack.addArrangedSubview(row)
                if fresh.contains(s.id) && !shownStepIds.isEmpty {
                    row.alpha = 0
                    row.transform = CGAffineTransform(translationX: 0, y: 8)
                    UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                        row.alpha = 1; row.transform = .identity
                    }
                }
            }
            shownStepIds = ids
        } else {
            for (row, s) in zip(stepsStack.arrangedSubviews.compactMap { $0 as? StepRow }, visible) { row.configure(s) }
        }
        stepsStack.isHidden = visible.isEmpty

        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Steps already say it's working; the bubble only appears for dots-before-anything or for text.
        bubble.isHidden = t.isEmpty && !visible.isEmpty
        if t.isEmpty {
            textLabel.attributedText = nil
            textLabel.isHidden = true
            dots.isHidden = false
            dots.start()
        } else {
            textLabel.isHidden = false
            stream(Markdown.render(Markdown.extractImages(t).0, color: Theme.theirsText, linkColor: .link))
            dots.isHidden = true
            dots.stop()
        }
    }

    private func stream(_ text: NSAttributedString) {
        let old = fullText?.string ?? ""
        fullText = text
        // Keep what's already shown if the new snapshot continues it; otherwise back up to where they agree.
        if !text.string.hasPrefix(String(old.prefix(revealed))) {
            var same = 0
            for (a, b) in zip(old.utf16, text.string.utf16) { if a != b { break }; same += 1 }
            revealed = min(revealed, same)
            batches = batches.compactMap { b in
                let end = min(NSMaxRange(b.range), revealed)
                return end > b.range.location ? (NSRange(location: b.range.location, length: end - b.range.location), b.born) : nil
            }
        }
        if UIAccessibility.isReduceMotionEnabled { revealed = text.length; batches = [] }
        applyReveal(now: CACurrentMediaTime())
        if revealed < text.length { startTicking() }
    }

    private func startTicking() {
        guard displayLink == nil, window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        displayLink = l
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let full = fullText else { stopTicking(); return }
        let now = l.targetTimestamp
        if revealed < full.length, now >= nextBatchAt {
            releaseBatch(full, now: now)
            nextBatchAt = now + Self.batchEvery
        }
        batches.removeAll { now - $0.born > Self.sweep }
        applyReveal(now: now)
        if revealed >= full.length, batches.isEmpty { stopTicking() }
    }

    /// The next few words. Bigger batches when a lot is waiting, so it never falls far behind.
    private func releaseBatch(_ full: NSAttributedString, now: CFTimeInterval) {
        let ns = full.string as NSString
        let backlog = full.length - revealed
        let words = max(3, min(18, backlog / 25))
        var end = revealed
        var count = 0
        while end < ns.length, count < words {
            // Skip to the end of the next word (and the space after it).
            while end < ns.length, Self.isSpace(ns.character(at: end)) { end += 1 }
            while end < ns.length, !Self.isSpace(ns.character(at: end)) { end += 1 }
            count += 1
            if end < ns.length, ns.character(at: end) == 10 { break }   // a line break ends the phrase
        }
        guard end > revealed else { return }
        batches.append((NSRange(location: revealed, length: end - revealed), now))
        revealed = end
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 }

    private func applyReveal(now: CFTimeInterval) {
        guard let full = fullText else { return }
        guard revealed < full.length || !batches.isEmpty else { textLabel.attributedText = full; return }
        let m = NSMutableAttributedString(attributedString: full)
        // Hidden tail: transparent, and without the backgrounds/underlines that would still draw.
        if revealed < full.length {
            let tail = NSRange(location: revealed, length: full.length - revealed)
            m.addAttribute(.foregroundColor, value: UIColor.clear, range: tail)
            m.removeAttribute(.backgroundColor, range: tail)
            m.removeAttribute(.underlineStyle, range: tail)
        }
        // Fresh batches: a left-to-right sweep from a faint glow to the final colour.
        let glow = traitCollection.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 1) : UIColor(white: 0.55, alpha: 1)
        for b in batches {
            let t = CGFloat((now - b.born) / Self.sweep)
            let n = max(1, b.range.length)
            for i in 0..<b.range.length {
                let idx = b.range.location + i
                // Each character starts a little after the one before it.
                let p = min(1, max(0, t * 1.6 - CGFloat(i) / CGFloat(n) * 0.6))
                guard p < 1 else { continue }
                let base = (full.attribute(.foregroundColor, at: idx, effectiveRange: nil) as? UIColor) ?? Theme.theirsText
                let c = Self.mix(glow, base.resolvedColor(with: traitCollection), p)
                m.addAttribute(.foregroundColor, value: c.withAlphaComponent(p * p * (3 - 2 * p)), range: NSRange(location: idx, length: 1))
            }
        }
        textLabel.attributedText = m
    }

    private static func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopTicking()
        fullText = nil
        revealed = 0
        batches = []
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dots.stop(); stopTicking() } else {
            if !dots.isHidden { dots.start() }
            if let f = fullText, revealed < f.length || !batches.isEmpty { startTicking() }
        }
    }
}

/// One agent step: "▸ Ran  git status | head -3".
final class StepRow: UIView {
    private let icon = SymbolBox("circle", size: 16, pointSize: 11)
    private let line = ShimmerLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: [icon, line])
        row.spacing = 7
        row.alignment = .center
        addSubview(row)
        row.pin(to: self)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: LiveStep) {
        icon.set(s.failed ? "exclamationmark.triangle" : s.icon,
                 tint: s.failed ? .systemOrange : (s.done ? .tertiaryLabel : .secondaryLabel))
        line.attributedText = ActivityStep.line(title: s.title, detail: s.detail, running: !s.done)
        line.isShimmering = !s.done
    }
}

/// Three-dot wave.
final class TypingDots: UIView {
    private var dots: [UIView] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView()
        stack.spacing = 4
        for _ in 0..<3 {
            let d = UIView()
            d.backgroundColor = .secondaryLabel
            d.layer.cornerRadius = 3.5
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 7).isActive = true
            d.heightAnchor.constraint(equalToConstant: 7).isActive = true
            stack.addArrangedSubview(d)
            dots.append(d)
        }
        addSubview(stack)
        stack.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var running = false
    func start() {
        guard !running, window != nil else { return }
        running = true
        let now = CACurrentMediaTime()
        for (i, d) in dots.enumerated() {
            let up = CAKeyframeAnimation(keyPath: "transform.translation.y")
            up.values = [0, -3.5, 0, 0]
            up.keyTimes = [0, 0.18, 0.4, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.3, 1, 0.3, 0.3]
            fade.keyTimes = [0, 0.18, 0.4, 1]
            let g = CAAnimationGroup()
            g.animations = [up, fade]
            g.duration = 1.2
            g.repeatCount = .infinity
            g.beginTime = now + Double(i) * 0.16
            g.fillMode = .backwards
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.layer.add(g, forKey: "wave")
        }
    }
    func stop() {
        running = false
        dots.forEach { $0.layer.removeAllAnimations() }
    }
}

// MARK: - Jump to bottom

/// Floating round button with a chevron; shows a count when replies arrive while scrolled up.
final class JumpButton: UIControl {
    private let bg = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
    private let badge = UILabel()
    private(set) var shown = false
    var count = 0 { didSet { updateBadge(oldValue: oldValue) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bg.backgroundColor = Theme.card
        bg.layer.cornerRadius = 20
        bg.layer.borderWidth = 1 / UIScreen.main.scale
        bg.isUserInteractionEnabled = false
        Theme.shadow(bg.layer, radius: 10, opacity: 0.12, y: 3)
        addSubview(bg)
        bg.pin(to: self)
        icon.tintColor = .label
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = Theme.mineText
        badge.backgroundColor = Theme.mineBubble
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.clipsToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40), heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: -5),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 5),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Scroll to latest"
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.5, y: 0.5).translatedBy(x: 0, y: 20)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (b: JumpButton, _: UITraitCollection) in b.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStroke() { bg.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        isUserInteractionEnabled = on
        if !on { count = 0 }
        UIView.animate(withDuration: on ? 0.5 : 0.25, delay: 0, usingSpringWithDamping: on ? 0.62 : 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = on ? 1 : 0
            self.transform = on ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5).translatedBy(x: 0, y: 20)
        }
    }

    private func updateBadge(oldValue: Int) {
        badge.text = count > 99 ? " 99+ " : " \(count) "
        accessibilityLabel = count > 0 ? "Scroll to latest, \(count) new" : "Scroll to latest"
        guard (count > 0) != !badge.isHidden || count > oldValue else { return }
        badge.isHidden = count == 0
        if count > oldValue {
            // New reply while you're reading above: badge pops.
            badge.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) { self.badge.transform = .identity }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard shown else { return }
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }
}

extension MessageCell: UIGestureRecognizerDelegate {}
