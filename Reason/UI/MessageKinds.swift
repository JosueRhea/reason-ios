import UIKit

// MARK: - Link chips

/// Capsule buttons for Session / PR / preview links under a message.
final class ChipsView: UIStackView {
    var onTap: ((LinkChip) -> Void)?
    private var chips: [LinkChip] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        alignment = .leading
        spacing = 6
    }
    required init(coder: NSCoder) { fatalError() }

    func configure(_ chips: [LinkChip]) {
        guard chips != self.chips else { return }
        self.chips = chips
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in chips.prefix(6) {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: c.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            cfg.imagePadding = 6
            var title = AttributedString(c.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            cfg.attributedTitle = title
            cfg.baseForegroundColor = .label
            cfg.background.backgroundColor = Theme.card
            cfg.background.strokeColor = Theme.cardStroke
            cfg.background.strokeWidth = 1
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
            cfg.titleLineBreakMode = .byTruncatingTail
            switch c.kind {
            case .session:
                cfg.image = UIImage(systemName: "arrow.triangle.branch", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            case .pullRequest:
                cfg.image = BrandIcon.github.image(size: 14)          // the real mark, tinted like the title
            case .preview, .link:
                if let host = Favicons.host(of: c.url), let fav = Favicons.icon(for: host) {
                    cfg.image = fav.withRenderingMode(.alwaysOriginal).resized(to: 14)
                }
            }
            b.configuration = cfg
            b.addAction(UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.onTap?(c)
            }, for: .touchUpInside)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            addArrangedSubview(b)
        }
        isHidden = chips.isEmpty
    }
}

// MARK: - Session report card

/// A child Session's report ("Session "X" finished. <result>…"), as a card instead of raw text.
final class ReportCell: UICollectionViewCell {
    static let reuse = "report"
    private let card = UIView()
    private let header = UIControl()
    private let statusIcon = SymbolBox("checkmark.circle.fill", size: 16, pointSize: 12, weight: .semibold)
    private let kicker = UILabel()
    private let title = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let body = UILabel()
    private let more = UIButton(type: .system)
    private let images = UIStackView()
    let chips = ChipsView()
    private var imageViews: [RemoteImageView] = []

    var onOpenSession: (() -> Void)?
    var onToggle: (() -> Void)?
    var onImageTap: ((RemoteImageView, Markdown.ImageRef) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        kicker.font = .systemFont(ofSize: 11, weight: .semibold)
        kicker.textColor = .secondaryLabel
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabel
        title.numberOfLines = 1
        kicker.isHidden = true
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let titles = UIStackView(arrangedSubviews: [kicker, title])
        titles.axis = .vertical
        titles.spacing = 1
        let headerRow = UIStackView(arrangedSubviews: [statusIcon, titles, chevron])
        headerRow.spacing = 7
        headerRow.alignment = .center
        headerRow.isUserInteractionEnabled = false
        header.addSubview(headerRow)
        headerRow.pin(to: header)
        header.addAction(UIAction { [weak self] _ in self?.onOpenSession?() }, for: .touchUpInside)

        body.numberOfLines = 6
        var mc = UIButton.Configuration.plain()
        mc.contentInsets = .zero
        mc.baseForegroundColor = .secondaryLabel
        more.configuration = mc
        more.contentHorizontalAlignment = .leading
        more.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        images.axis = .vertical
        images.spacing = 6

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        divider.isHidden = true
        // The report itself is quoted under its header, like the messages sent to Sessions.
        let quoted = UIStackView(arrangedSubviews: [body, more, images, chips])
        quoted.axis = .vertical
        quoted.spacing = 8
        quoted.setCustomSpacing(4, after: body)
        quoted.alignment = .leading
        quoted.isLayoutMarginsRelativeArrangement = true
        quoted.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 15, bottom: 2, trailing: 0)
        let bar = UIView()
        bar.backgroundColor = .tertiaryLabel
        bar.layer.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        quoted.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: quoted.leadingAnchor, constant: 6),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: body.topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -2),
        ])
        let stack = UIStackView(arrangedSubviews: [header, divider, quoted])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MessageCell.theirsInset),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MessageCell.theirsInset),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (c: ReportCell, _: UITraitCollection) in c.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStroke() { card.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }

    /// The first few lines' worth of a report (whole lines, at most ~8 of them).
    static func head(_ text: String) -> String {
        guard text.count > 700 else { return text }
        var out: [Substring] = []
        var n = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(line)
            n += line.count
            if out.count >= 8 || n > 600 { break }
        }
        return out.joined(separator: "\n")
    }

    func configure(_ m: MessageModel) {
        guard case .report(let t, let state, _) = m.style else { return }
        let (symbol, tint, word): (String, UIColor, String) = {
            switch state {
            case .finished: return ("checkmark.circle.fill", .systemGreen, "SESSION FINISHED")
            case .failed: return ("xmark.circle.fill", .systemRed, "SESSION FAILED")
            case .stopped: return ("stop.circle.fill", .secondaryLabel, "SESSION STOPPED")
            case .needsInput: return ("exclamationmark.circle.fill", .systemOrange, "SESSION NEEDS YOU")
            }
        }()
        statusIcon.set(symbol, tint: tint)
        kicker.text = word + (m.footer.map { "  ·  \($0)" } ?? "")
        // "Set up acme/app finished"
        let stateWord = word.replacingOccurrences(of: "SESSION ", with: "").lowercased()
        let line = NSMutableAttributedString(string: t, attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.label])
        line.append(NSAttributedString(string: " " + stateWord, attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor.secondaryLabel]))
        title.attributedText = line
        title.lineBreakMode = .byTruncatingMiddle
        // Collapsed shows four lines: format only the start of a long report, not all of it.
        let preview = m.expanded ? m.text : Self.head(m.text)
        body.attributedText = Favicons.decorate(Markdown.render(preview, color: .secondaryLabel, font: .systemFont(ofSize: 14), linkColor: .link),
                                                font: .systemFont(ofSize: 14), tint: .link)
        body.numberOfLines = m.expanded ? 0 : 4
        let width = (window?.bounds.width ?? UIScreen.main.bounds.width) - 2 * MessageCell.theirsInset - 15
        let long = preview.count < m.text.count || (body.attributedText?.exceeds(lines: 4, width: width, font: .systemFont(ofSize: 14)) ?? false)
        more.isHidden = !long
        var c = more.configuration
        c?.attributedTitle = AttributedString(m.expanded ? "Show less" : "Show more",
                                              attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .medium)]))
        more.configuration = c

        while imageViews.count < m.images.count {
            let v = RemoteImageView()
            v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            imageViews.append(v)
            images.addArrangedSubview(v)
        }
        for (i, v) in imageViews.enumerated() {
            v.isHidden = i >= m.images.count || !m.expanded && i > 0
            if i < m.images.count { v.configure(m.images[i], width: 230) }
        }
        images.isHidden = m.images.isEmpty
        chips.configure(m.chips.filter { if case .session = $0.kind { return false }; return true })
    }

    @objc private func imageTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view as? RemoteImageView, let ref = v.ref else { return }
        onImageTap?(v, ref)
    }
}

// MARK: - System notice

final class NoticeCell: UICollectionViewCell {
    static let reuse = "notice"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = SymbolBox("info.circle", size: 14, pointSize: 11, weight: .medium, tint: .tertiaryLabel)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        label.textAlignment = .center
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 5
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            row.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            row.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -64),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: MessageModel) { label.text = Markdown.plain(m.text) }
}

// MARK: - "Message from …" (another agent or app)

/// Desktop shows messages other clients sent as a one-line "Message from x · y"; tap to read them.
final class AgentNoteCell: UICollectionViewCell {
    static let reuse = "agentNote"
    private let header = UIControl()
    private let headerLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private let bubble = BubbleView()
    private let body = UILabel()
    private let column = UIStackView()
    var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = SymbolBox("cpu", size: 14, pointSize: 11, weight: .medium, tint: .tertiaryLabel)
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.textColor = .tertiaryLabel
        headerLabel.lineBreakMode = .byTruncatingMiddle
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let row = UIStackView(arrangedSubviews: [icon, headerLabel, chevron])
        row.spacing = 5
        row.alignment = .center
        row.isUserInteractionEnabled = false
        header.addSubview(row)
        row.pin(to: header, insets: UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        header.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)

        bubble.side = .right
        bubble.fillColor = Theme.theirsBubble
        body.numberOfLines = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])

        column.axis = .vertical
        column.alignment = .trailing
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        [header, bubble].forEach(column.addArrangedSubview)
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MessageCell.outerInset),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 48),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: MessageModel) {
        guard case .agentNote(let from) = m.style else { return }
        headerLabel.text = "Message from \(from)"
        chevron.transform = m.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        body.attributedText = Markdown.render(m.text, color: Theme.theirsText, font: .systemFont(ofSize: 15), linkColor: .link)
        bubble.isHidden = !m.expanded
    }
}

// MARK: - "Sent a message to ● Session" (the Reason driving a child Session)

/// What the Reason sent one of its child Sessions, as a quoted card:
///   ↗ Sent a message to  [● Port reason-desk from gpui to Rune ›]
///   ┃ Let's finish the remaining polish on the Rune port…
///   Show more
final class ChildEventCell: UICollectionViewCell {
    static let reuse = "childEvent"

    let column = UIStackView()
    private let verbIcon = SymbolBox("arrow.up.right", size: 16, pointSize: 11)
    private let verb = UILabel()
    private let pill = UIControl()
    private let pillAvatar = AvatarView()
    private let pillTitle = UILabel()
    private let statusDot = UIView()
    private let quoteBox = UIControl()
    private let quoteBar = UIView()
    private let body = UILabel()
    private let more = UILabel()
    private let nowRow = UIStackView()           // running: what the child is doing right now
    private let nowIcon = SymbolBox("terminal", size: 16, pointSize: 10)
    private let nowLabel = ShimmerLabel()
    var onOpen: (() -> Void)?
    var onToggle: (() -> Void)?
    private var collapsed = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        verb.font = .systemFont(ofSize: 13, weight: .medium)
        verb.textColor = .secondaryLabel
        verb.setContentHuggingPriority(.required, for: .horizontal)
        verb.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Session pill: avatar · title · status dot · chevron
        pill.backgroundColor = .tertiarySystemFill
        pill.layer.cornerRadius = 13
        pill.layer.cornerCurve = .continuous
        pillAvatar.animatesIdle = false
        pillAvatar.translatesAutoresizingMaskIntoConstraints = false
        pillTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        pillTitle.lineBreakMode = .byTruncatingTail
        statusDot.layer.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let pillRow = UIStackView(arrangedSubviews: [pillAvatar, pillTitle, statusDot, chevron])
        pillRow.spacing = 6
        pillRow.alignment = .center
        pillRow.isUserInteractionEnabled = false
        pill.addSubview(pillRow)
        pillRow.pin(to: pill, insets: UIEdgeInsets(top: 4, left: 5, bottom: 4, right: 9))
        NSLayoutConstraint.activate([
            pillAvatar.widthAnchor.constraint(equalToConstant: 18), pillAvatar.heightAnchor.constraint(equalToConstant: 18),
            statusDot.widthAnchor.constraint(equalToConstant: 7), statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        pill.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onOpen?()
        }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [verbIcon, verb, pill])
        header.spacing = 6
        header.setCustomSpacing(8, after: verb)
        header.alignment = .center

        // Quoted message
        quoteBox.backgroundColor = .clear
        quoteBar.backgroundColor = .tertiaryLabel
        quoteBar.layer.cornerRadius = 1.5
        quoteBar.translatesAutoresizingMaskIntoConstraints = false
        body.numberOfLines = 4
        more.font = .systemFont(ofSize: 12, weight: .semibold)
        more.textColor = .secondaryLabel
        // Body + "Show more" in a stack so a hidden toggle takes no space.
        let textStack = UIStackView(arrangedSubviews: [body, more])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading
        textStack.isUserInteractionEnabled = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        [quoteBar, textStack].forEach(quoteBox.addSubview)
        NSLayoutConstraint.activate([
            quoteBar.leadingAnchor.constraint(equalTo: quoteBox.leadingAnchor, constant: 6),
            quoteBar.topAnchor.constraint(equalTo: body.topAnchor, constant: 2),
            quoteBar.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -2),
            quoteBar.widthAnchor.constraint(equalToConstant: 3),
            textStack.topAnchor.constraint(equalTo: quoteBox.topAnchor, constant: 2),
            textStack.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: quoteBox.trailingAnchor, constant: -14),
            textStack.bottomAnchor.constraint(equalTo: quoteBox.bottomAnchor, constant: -2),
        ])
        quoteBox.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)

        [nowIcon, nowLabel].forEach(nowRow.addArrangedSubview)
        nowRow.spacing = 7
        nowRow.alignment = .center
        nowRow.isHidden = true

        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 7
        column.translatesAutoresizingMaskIntoConstraints = false
        [header, nowRow, quoteBox].forEach(column.addArrangedSubview)
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MessageCell.theirsInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),
            quoteBox.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.86),
            header.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.9),
            nowRow.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.86),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (c: ChildEventCell, _: UITraitCollection) in c.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateStroke() { quoteBox.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }

    func configure(_ m: MessageModel, appearance: Appearance?) {
        guard case .childEvent(let v, let t, _, let status) = m.style else { return }
        let started = v == "Started"
        verbIcon.set(started ? "arrow.triangle.branch" : "arrow.up.right")
        verb.text = started ? "Started" : "Sent a message to"
        pillTitle.text = t
        pillAvatar.configure(appearance)
        statusDot.layer.removeAllAnimations()
        switch status {
        case "running":
            statusDot.backgroundColor = .systemBlue
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.25; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            statusDot.layer.add(a, forKey: "pulse")
        case "failed": statusDot.backgroundColor = .systemRed
        case "stopped": statusDot.backgroundColor = .systemGray3
        case "finished": statusDot.backgroundColor = .systemGreen
        default: statusDot.backgroundColor = .clear
        }
        statusDot.isHidden = status == nil

        // The Reason writes these for the agent ("The user asks: …"); show them as-is, quoted.
        body.attributedText = Markdown.render(m.text, color: .secondaryLabel, font: .systemFont(ofSize: 14), linkColor: .link)
        collapsed = !m.expanded
        body.numberOfLines = collapsed ? 3 : 0
        // Measure at the quote's real text width: 86% of the row, minus bar and padding.
        let width = (window?.bounds.width ?? UIScreen.main.bounds.width) * 0.86 - 33
        let long = body.attributedText?.exceeds(lines: 3, width: width, font: .systemFont(ofSize: 14)) ?? false
        more.isHidden = !long
        more.text = collapsed ? "Show more" : "Show less"
        quoteBox.isHidden = m.text.isEmpty
        let now = status == "running" ? m.now : nil
        let text = now.map { ActivityStep.line(title: $0.title, detail: $0.detail, running: !$0.done) }
        if text?.string != nowLabel.attributedText?.string || nowRow.isHidden != (now == nil) {
            let changing = nowLabel.attributedText != nil && text != nil && window != nil
            nowLabel.attributedText = text
            if let now { nowIcon.set(now.icon, tint: .secondaryLabel) }
            nowRow.isHidden = now == nil
            // Each new command rolls in from below.
            if changing {
                let t = CATransition(); t.type = .push; t.subtype = .fromTop; t.duration = 0.3
                t.timingFunction = CAMediaTimingFunction(name: .easeOut)
                nowRow.layer.add(t, forKey: "tick")
            }
        }
        nowLabel.isShimmering = now.map { !$0.done } ?? false
        accessibilityLabel = "\(verb.text ?? "") \(t)" + (text.map { ", \($0.string)" } ?? "")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        column.transform = .identity
        column.alpha = 1
    }
}
