import UIKit

struct ActivityModel: Hashable {
    let id: String
    var turn: ActivityTurn
    var expanded: Bool
    var live: Bool            // the turn is still running
    var shots: [Markdown.ImageRef] = []   // screenshots it showed you
}

/// What a turn did, above its reply: "Ran 12 commands and read 4 files · 2m 14s ›".
/// Tap to unfold every step; tap a step for its full command and output.
final class ActivityCell: UICollectionViewCell {
    static let reuse = "activity"

    let column = UIStackView()
    private let header = UIControl()
    private let icon = SymbolBox("terminal", size: 16, pointSize: 11)
    private let summary = ShimmerLabel()
    private let meta = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let current = UIStackView()      // running + collapsed: what it's doing now
    private let currentIcon = SymbolBox("terminal", size: 16, pointSize: 10)
    private let currentLine = ShimmerLabel()
    private let stepsBox = UIView()
    private let rail = UIView()
    private let steps = UIStackView()
    private var model: ActivityModel?
    private var timer: Timer?

    var onToggle: (() -> Void)?
    var onStep: ((ActivityStep) -> Void)?
    var onImageTap: ((RemoteImageView, Markdown.ImageRef) -> Void)?
    private let shotScroll = UIScrollView()
    private let shotStack = UIStackView()
    private var shotViews: [RemoteImageView] = []
    static let shotHeight: CGFloat = 132

    override init(frame: CGRect) {
        super.init(frame: frame)
        meta.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        meta.textColor = .tertiaryLabel
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let iconSlot = UIView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(icon)
        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 16), iconSlot.heightAnchor.constraint(equalToConstant: 16),
            icon.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])
        let row = UIStackView(arrangedSubviews: [iconSlot, summary, meta, chevron])
        row.spacing = 7
        row.setCustomSpacing(5, after: meta)
        row.alignment = .center
        row.isUserInteractionEnabled = false
        header.addSubview(row)
        row.pin(to: header, insets: UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0))
        header.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        header.addAction(UIAction { [weak self] _ in self?.header.alpha = 0.5 }, for: [.touchDown, .touchDragEnter])
        header.addAction(UIAction { [weak self] _ in
            UIView.animate(withDuration: 0.2) { self?.header.alpha = 1 }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

        current.addArrangedSubview(currentIcon)
        current.addArrangedSubview(currentLine)
        current.spacing = 7
        current.alignment = .center

        // Steps hang off a thin rail under the header icon.
        rail.backgroundColor = .separator
        rail.translatesAutoresizingMaskIntoConstraints = false
        steps.axis = .vertical
        steps.spacing = 0
        steps.translatesAutoresizingMaskIntoConstraints = false
        stepsBox.addSubview(rail)
        stepsBox.addSubview(steps)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: stepsBox.leadingAnchor, constant: 7.5),
            rail.widthAnchor.constraint(equalToConstant: 1),
            rail.topAnchor.constraint(equalTo: stepsBox.topAnchor, constant: 2),
            rail.bottomAnchor.constraint(equalTo: stepsBox.bottomAnchor, constant: -8),
            steps.leadingAnchor.constraint(equalTo: stepsBox.leadingAnchor, constant: 18),
            steps.trailingAnchor.constraint(equalTo: stepsBox.trailingAnchor),
            steps.topAnchor.constraint(equalTo: stepsBox.topAnchor),
            steps.bottomAnchor.constraint(equalTo: stepsBox.bottomAnchor),
        ])

        // Screenshots it showed you: a strip of thumbnails, visible even when the steps are folded.
        shotScroll.showsHorizontalScrollIndicator = false
        shotScroll.clipsToBounds = false
        shotStack.spacing = 8
        shotStack.alignment = .center
        shotStack.translatesAutoresizingMaskIntoConstraints = false
        shotScroll.addSubview(shotStack)
        NSLayoutConstraint.activate([
            shotStack.topAnchor.constraint(equalTo: shotScroll.contentLayoutGuide.topAnchor),
            shotStack.bottomAnchor.constraint(equalTo: shotScroll.contentLayoutGuide.bottomAnchor),
            shotStack.leadingAnchor.constraint(equalTo: shotScroll.contentLayoutGuide.leadingAnchor),
            shotStack.trailingAnchor.constraint(equalTo: shotScroll.contentLayoutGuide.trailingAnchor),
            shotStack.heightAnchor.constraint(equalTo: shotScroll.frameLayoutGuide.heightAnchor),
            shotScroll.heightAnchor.constraint(equalToConstant: Self.shotHeight),
        ])
        shotScroll.isHidden = true

        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        [header, current, shotScroll, stepsBox].forEach(column.addArrangedSubview)
        column.setCustomSpacing(8, after: shotScroll)
        column.setCustomSpacing(2, after: header)
        contentView.addSubview(column)
        let leading: CGFloat = MessageCell.outerInset + 4
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: leading),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            column.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.92),
        ])
        let fill = column.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.92)
        fill.priority = .defaultLow
        fill.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: ActivityModel) {
        let sameSteps = model?.turn.steps == m.turn.steps && model?.expanded == m.expanded
        model = m
        let t = m.turn
        let failed = t.failedCount
        summary.attributedText = NSAttributedString(string: m.live ? "Working" : t.summary, attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor.secondaryLabel,
        ])
        summary.isShimmering = m.live
        updateMeta()
        let mainIcon = t.tools.contains { $0.kind == .command } ? "terminal" : (t.tools.first?.icon ?? "sparkles")
        icon.set(failed > 0 && !m.live ? "exclamationmark.triangle" : mainIcon, tint: failed > 0 && !m.live ? .systemOrange : .secondaryLabel)
        chevron.transform = m.expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        chevron.isHidden = t.steps.isEmpty

        let now = t.tools.last(where: { !$0.done }) ?? (m.live ? t.tools.last : nil)
        if let now {
            currentIcon.set(now.icon, tint: .secondaryLabel)
            currentLine.attributedText = ActivityStep.line(title: now.title, detail: now.detail, running: !now.done)
        }
        currentLine.isShimmering = now.map { !$0.done } ?? false
        current.isHidden = m.expanded || !m.live || now == nil

        configureShots(m.shots)
        stepsBox.isHidden = !m.expanded
        if m.expanded && !sameSteps {
            steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for s in t.steps {
                if s.kind == .note {
                    let l = UILabel()
                    l.text = s.detail
                    l.font = .systemFont(ofSize: 13)
                    l.textColor = .secondaryLabel
                    l.numberOfLines = 3
                    let wrap = UIView()
                    wrap.addSubview(l)
                    l.pin(to: wrap, insets: UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0))
                    steps.addArrangedSubview(wrap)
                } else {
                    let r = ActivityStepRow()
                    r.configure(s, live: m.live)
                    r.addAction(UIAction { [weak self] _ in self?.onStep?(s) }, for: .touchUpInside)
                    steps.addArrangedSubview(r)
                }
            }
        }
        accessibilityLabel = "\(summary.accessibilityLabel ?? ""), \(meta.text ?? "")"

        timer?.invalidate()
        if m.live {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMeta() }
            }
        }
    }

    private func configureShots(_ refs: [Markdown.ImageRef]) {
        shotScroll.isHidden = refs.isEmpty
        column.setCustomSpacing(refs.isEmpty ? 0 : 6, after: current.isHidden ? header : current)
        while shotViews.count < refs.count {
            let v = RemoteImageView()
            v.layer.cornerRadius = 12
            v.layer.borderWidth = 1 / UIScreen.main.scale
            v.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor
            v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shotTapped(_:))))
            shotViews.append(v)
            shotStack.addArrangedSubview(v)
        }
        for (i, v) in shotViews.enumerated() {
            guard i < refs.count else { v.isHidden = true; continue }
            v.isHidden = false
            // Fixed height, width from the image's own shape (clamped so a tall phone shot stays narrow).
            let w = min(260, max(80, Self.shotHeight / max(refs[i].aspect, 0.3)))
            v.configure(refs[i], width: w)
            v.accessibilityLabel = refs[i].alt
        }
    }

    @objc private func shotTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view as? RemoteImageView, let ref = v.ref else { return }
        onImageTap?(v, ref)
    }

    private func updateMeta() {
        guard let m = model else { return }
        let t = m.turn
        var bits: [String] = []
        if m.live {
            bits.append(ActivityTurn.durationText(Date().timeIntervalSince(t.start)))
            let n = t.tools.count
            if n > 0 { bits.append("\(n) step\(n == 1 ? "" : "s")") }
        } else {
            bits.append(ActivityTurn.durationText(t.duration))
            if t.failedCount > 0 { bits.append("\(t.failedCount) failed") }
        }
        meta.text = bits.joined(separator: " · ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        model = nil
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

/// One step: icon · verb · `detail` · duration. Highlights on touch.
final class ActivityStepRow: UIControl {
    private let icon = SymbolBox("terminal", size: 16, pointSize: 10)
    private let line = ShimmerLabel()
    private let trailing = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = .quaternaryLabel
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, line, trailing])
        row.spacing = 6
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: ActivityStep, live: Bool) {
        icon.set(s.failed ? "exclamationmark.triangle" : s.icon, tint: s.failed ? .systemOrange : .tertiaryLabel)
        let running = !s.done && live
        line.attributedText = ActivityStep.line(title: s.title, detail: s.detail, running: running)
        line.isShimmering = running
        if running { icon.set(s.icon, tint: .secondaryLabel) }
        trailing.text = s.durationMs.flatMap { $0 >= 1000 ? ActivityTurn.durationText(Double($0) / 1000) : nil }
        trailing.isHidden = running || trailing.text == nil
        accessibilityLabel = [s.title, s.detail, s.failed ? "failed" : nil].compactMap { $0 }.joined(separator: " ")
        accessibilityTraits = .button
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: isHighlighted ? 0 : 0.2) { self.alpha = self.isHighlighted ? 0.45 : 1 } }
    }
}

/// A step in full: the command (or code, or file), then what came back.
final class ActivityStepViewController: UIViewController {
    private let step: ActivityStep

    init(step: ActivityStep) {
        self.step = step
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = 22
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.groupedBackground
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.pin(to: view)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        // Header: icon · title, then status · duration.
        let icon = SymbolBox(step.failed ? "exclamationmark.triangle" : step.icon, size: 28, pointSize: 14,
                             tint: step.failed ? .systemOrange : .label)
        icon.backgroundColor = .tertiarySystemFill
        icon.layer.cornerRadius = 8
        icon.layer.cornerCurve = .continuous
        let title = UILabel()
        title.text = [step.title, step.kind == .command ? nil : step.detail].compactMap { $0 }.joined(separator: " ")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.numberOfLines = 2
        let status = UILabel()
        var bits = [step.failed ? "Failed" : (step.done ? "Completed" : "Running")]
        if let ms = step.durationMs { bits.append(ms < 1000 ? "\(ms) ms" : ActivityTurn.durationText(Double(ms) / 1000)) }
        status.text = bits.joined(separator: " · ")
        status.font = .systemFont(ofSize: 13)
        status.textColor = step.failed ? .systemOrange : .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [title, status])
        titles.axis = .vertical
        titles.spacing = 2
        let head = UIStackView(arrangedSubviews: [icon, titles])
        head.spacing = 12
        head.alignment = .center
        stack.addArrangedSubview(head)

        let inputLabel: String = switch step.kind {
        case .command: "Command"
        case .edit: "Content"
        case .code, .session: "Code"
        case .read: "File"
        default: "Input"
        }
        if let input = step.input, !input.isEmpty { stack.addArrangedSubview(CodeBlock(title: inputLabel, text: input, prompt: step.kind == .command)) }
        if let out = step.output, !out.isEmpty {
            stack.addArrangedSubview(CodeBlock(title: "Output", text: out, prompt: false))
        } else if step.done {
            let l = UILabel()
            l.text = "No output."
            l.font = .systemFont(ofSize: 14)
            l.textColor = .tertiaryLabel
            stack.addArrangedSubview(l)
        }
    }
}

/// A titled monospace block with a Copy button; selectable, wraps long lines.
private final class CodeBlock: UIView {
    init(title: String, text: String, prompt: Bool) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = title.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        let copy = UIButton(type: .system)
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        c.title = "Copy"
        c.imagePadding = 4
        c.baseForegroundColor = .secondaryLabel
        c.contentInsets = .zero
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0; a.font = .systemFont(ofSize: 12, weight: .medium); return a }
        copy.configuration = c
        copy.addAction(UIAction { [weak copy] _ in
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            copy?.configuration?.title = "Copied"
            copy?.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        }, for: .touchUpInside)
        let top = UIStackView(arrangedSubviews: [label, UIView(), copy])
        top.alignment = .center

        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        let mono = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let body = NSMutableAttributedString()
        if prompt { body.append(NSAttributedString(string: "$ ", attributes: [.font: mono, .foregroundColor: UIColor.tertiaryLabel])) }
        body.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: UIColor.label]))
        tv.attributedText = body
        let box = UIView()
        box.backgroundColor = Theme.card
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1 / UIScreen.main.scale
        box.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor
        box.addSubview(tv)
        tv.pin(to: box)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: CodeBlock, _: UITraitCollection) in
            box.layer.borderColor = Theme.cardStroke.resolvedColor(with: v.traitCollection).cgColor
        }

        let s = UIStackView(arrangedSubviews: [top, box])
        s.axis = .vertical
        s.spacing = 6
        addSubview(s)
        s.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Shimmer

/// One line of text with a band of light sweeping across it while work is in progress, and a soft
/// fade at the trailing edge instead of an ellipsis. Static (no sweep) when not shimmering or with
/// Reduce Motion on.
final class ShimmerLabel: UIView {
    private let base = UILabel()
    private let shine = UILabel()
    private let band = CAGradientLayer()
    private let fade = CAGradientLayer()

    var isShimmering = false { didSet { if isShimmering != oldValue { updateAnimation() } } }

    var attributedText: NSAttributedString? {
        didSet {
            base.attributedText = attributedText
            // The shine is the same text in full-strength ink, revealed only under the moving band.
            let s = NSMutableAttributedString(attributedString: attributedText ?? NSAttributedString())
            s.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: s.length))
            shine.attributedText = s
            invalidateIntrinsicContentSize()   // reused cells change text; the row must re-measure
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for l in [base, shine] {
            l.numberOfLines = 1
            l.lineBreakMode = .byClipping
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.setContentHuggingPriority(.defaultHigh, for: .vertical)
            addSubview(l)
            l.pin(to: self)
        }
        band.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, 0, 0]
        shine.layer.mask = band
        shine.isHidden = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        layer.mask = fade
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { base.intrinsicContentSize }
    override var accessibilityLabel: String? { get { base.attributedText?.string } set {} }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = max(bounds.width, 1)
        fade.frame = bounds
        // Only fade when the text actually runs past the edge.
        let overflows = base.intrinsicContentSize.width > bounds.width + 0.5
        let edge = overflows ? max(0, (w - 28) / w) : 1
        fade.locations = [0, NSNumber(value: Double(edge)), 1]
        band.frame = shine.bounds
        CATransaction.commit()
        if isShimmering, band.animation(forKey: "sweep") == nil { updateAnimation() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()    // animations are dropped when a view leaves the window
    }

    private func updateAnimation() {
        band.removeAllAnimations()
        let on = isShimmering && window != nil && !UIAccessibility.isReduceMotionEnabled
        shine.isHidden = !on
        guard on else { return }
        // A narrow band crosses left → right, rests, crosses again. Its width is relative to the text.
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.35, -0.175, 0]
        sweep.toValue = [1, 1.175, 1.35]
        sweep.duration = 1.5
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let g = CAAnimationGroup()
        g.animations = [sweep]
        g.duration = 2.1
        g.repeatCount = .infinity
        g.isRemovedOnCompletion = false
        band.add(g, forKey: "sweep")
    }
}

extension ActivityStep {
    /// "Ran" → "Running", for a step that hasn't finished.
    static func presentTense(_ title: String) -> String {
        let map = ["Ran code": "Running code", "Ran": "Running", "Read": "Reading", "Edited": "Editing", "Wrote": "Writing",
                   "Searched": "Searching", "Used": "Using", "Started session": "Starting session",
                   "Messaged session": "Messaging session", "Stopped session": "Stopping session", "Thinking": "Thinking"]
        return map[title] ?? title
    }

    /// "Running" in medium weight, then the command in monospace.
    static func line(title: String, detail: String?, running: Bool, size: CGFloat = 13) -> NSAttributedString {
        let s = NSMutableAttributedString(string: running ? presentTense(title) : title, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: running ? UIColor.secondaryLabel : UIColor.tertiaryLabel,
        ])
        if let d = detail, !d.isEmpty {
            s.append(NSAttributedString(string: " " + d, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                .foregroundColor: running ? UIColor.secondaryLabel.withAlphaComponent(0.8) : UIColor.tertiaryLabel,
            ]))
        }
        return s
    }
}
