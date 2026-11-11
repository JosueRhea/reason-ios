import UIKit

/// The agent is waiting on you: a question, a secret, or an approval. Answer right in the chat.
final class RequestCell: UICollectionViewCell, UITextFieldDelegate {
    static let reuse = "request"

    var onAnswer: (([(selected: [String], text: String?)]) -> Void)?
    var onAction: ((String, String?) -> Void)?   // approve | deny | secret | cancel, value
    var onOpen: ((URL) -> Void)?

    private let card = UIView()
    private let stack = UIStackView()
    private var request: InputRequest?
    private var selections: [Int: Set<String>] = [:]
    private var textFields: [Int: UITextField] = [:]
    private var secretField: UITextField?
    private var busyButtons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.card
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1.5
        card.translatesAutoresizingMaskIntoConstraints = false
        Theme.shadow(card.layer, radius: 14, opacity: 0.06, y: 3)
        contentView.addSubview(card)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: MessageCell.outerInset),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -MessageCell.outerInset),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (c: RequestCell, _: UITraitCollection) in c.updateStroke() }
        updateStroke()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A secret card is a quiet inline row, as Reason shows it; other requests keep the pulsing outline.
    private var calm = false
    private var hairlines: [UIView] = []

    private func updateStroke() {
        card.layer.borderWidth = calm ? 1 : 1.5
        card.layer.cornerRadius = calm ? 16 : 20
        for v in hairlines { v.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor }
        card.layer.borderColor = (calm ? UIColor.separator : UIColor.label.withAlphaComponent(0.85)).resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A gentle pulse on the border so a waiting request is hard to miss.
        card.layer.removeAnimation(forKey: "attention")
        guard window != nil, !calm, !UIAccessibility.isReduceMotionEnabled else { return }
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = UIColor.label.withAlphaComponent(0.85).resolvedColor(with: traitCollection).cgColor
        a.toValue = UIColor.label.withAlphaComponent(0.25).resolvedColor(with: traitCollection).cgColor
        a.duration = 1.2
        a.autoreverses = true
        a.repeatCount = .infinity
        card.layer.add(a, forKey: "attention")
    }

    func configure(_ r: InputRequest) {
        guard r != request else { return }
        request = r
        selections = [:]
        textFields = [:]
        secretField = nil
        busyButtons = []
        hairlines = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        calm = r.type == "secret" && (r.can("secret") || r.can("cancel"))
        updateStroke()
        if window != nil { didMoveToWindow() }
        if calm { buildCompactSecret(r); return }

        // Header
        let icon = SymbolBox(Self.symbol(r.type), size: 22, pointSize: 15, weight: .semibold, tint: .label)
        let kicker = UILabel()
        kicker.text = Self.kicker(r.type)
        kicker.font = .systemFont(ofSize: 11, weight: .semibold)
        kicker.textColor = .secondaryLabel
        let title = UILabel()
        title.text = r.label ?? "The Reason needs you"
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.numberOfLines = 0
        let titles = UIStackView(arrangedSubviews: [kicker, title])
        titles.axis = .vertical
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [icon, titles])
        header.spacing = 10
        header.alignment = .center
        stack.addArrangedSubview(header)

        if let reason = r.reason, !reason.isEmpty {
            stack.addArrangedSubview(body(reason))
        }

        switch r.type {
        case "question": buildQuestion(r)
        case "secret": buildSecret(r)
        case "network_hosts": buildApproval(r, lines: r.networkHosts?.hosts ?? [], mono: true)
        case "permission_rules": buildApproval(r, lines: r.permissionRules?.changes ?? [], mono: false)
        default: buildOpenOnly(r)
        }
    }

    // MARK: Builders

    /// [key] NAME / Stored securely, never shown in chat
    /// [ value field ············ ] Not now  (Save)
    private func buildCompactSecret(_ r: InputRequest) {
        let s = r.secretRequest
        let key = UIImageView(image: UIImage(systemName: "key.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)))
        key.tintColor = .secondaryLabel
        key.contentMode = .center
        let keyBox = UIView()
        keyBox.layer.cornerRadius = 10
        keyBox.layer.cornerCurve = .continuous
        keyBox.layer.borderWidth = 1
        keyBox.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        hairlines.append(keyBox)
        keyBox.addSubview(key)
        key.pin(to: keyBox, insets: .zero)
        keyBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([keyBox.widthAnchor.constraint(equalToConstant: 36), keyBox.heightAnchor.constraint(equalToConstant: 36)])
        let title = UILabel()
        title.text = s?.name ?? r.label ?? "Secret"
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let sub = UILabel()
        sub.text = "Stored securely, never shown in chat"
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [title, sub])
        titles.axis = .vertical
        titles.spacing = 1
        let header = UIStackView(arrangedSubviews: [keyBox, titles])
        header.spacing = 12
        header.alignment = .center
        stack.addArrangedSubview(header)

        let tf = field(placeholder: s?.placeholder ?? s?.valuePrefix.map { "\($0)…" } ?? "Paste value")
        tf.isSecureTextEntry = true
        tf.textContentType = .password
        tf.font = .systemFont(ofSize: 14)
        tf.backgroundColor = .clear
        tf.layer.cornerRadius = 10
        tf.layer.borderWidth = 1
        tf.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        tf.constraints.first { $0.firstAttribute == .height }?.constant = 36
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hairlines.append(tf)
        secretField = tf
        let row = UIStackView(arrangedSubviews: [tf])
        row.spacing = 8
        row.alignment = .center
        if r.can("cancel") {
            let b = UIButton(type: .system)
            var c = UIButton.Configuration.plain()
            c.title = "Not now"
            c.baseForegroundColor = .label
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            c.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 14); return a }
            b.configuration = c
            b.addAction(UIAction { [weak self] _ in self?.setBusy(); self?.onAction?("cancel", nil) }, for: .touchUpInside)
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            busyButtons.append(b)
            row.addArrangedSubview(b)
        }
        if r.can("secret") {
            let b = primary("Save") { [weak self] in
                guard let self, let v = self.secretField?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { self?.shake(); return }
                self.setBusy()
                self.onAction?("secret", v)
            }
            var c = b.configuration
            c?.buttonSize = .small
            c?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            c?.titleTextAttributesTransformer = .init { var a = $0; a.font = .systemFont(ofSize: 14, weight: .medium); return a }
            b.configuration = c
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(b)
        }
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(12, after: header)
    }

    private func buildQuestion(_ r: InputRequest) {
        let questions = r.question?.questions ?? []
        for (i, q) in questions.enumerated() {
            if let h = q.header, !h.isEmpty {
                let l = UILabel(); l.text = h.uppercased(); l.font = .systemFont(ofSize: 11, weight: .semibold); l.textColor = .tertiaryLabel
                stack.addArrangedSubview(l)
            }
            stack.addArrangedSubview(body(q.question, size: 15, color: .label))
            if let opts = q.options, !opts.isEmpty {
                let col = UIStackView()
                col.axis = .vertical
                col.spacing = 6
                for o in opts {
                    let b = OptionButton(label: o.label, detail: o.description)
                    b.addAction(UIAction { [weak self, weak b] _ in
                        guard let self, let b else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        var set = self.selections[i] ?? []
                        if set.contains(o.label) { set.remove(o.label) } else {
                            if q.multiSelect != true { set = [] }
                            set.insert(o.label)
                        }
                        self.selections[i] = set
                        for case let other as OptionButton in col.arrangedSubviews { other.setOn(set.contains(other.label)) }
                        _ = b
                    }, for: .touchUpInside)
                    col.addArrangedSubview(b)
                }
                stack.addArrangedSubview(col)
            }
            let tf = field(placeholder: q.options?.isEmpty == false ? "Or answer in your own words" : "Your answer")
            textFields[i] = tf
            stack.addArrangedSubview(tf)
        }
        let send = primary("Send answer") { [weak self] in
            guard let self else { return }
            let answers = questions.indices.map { i in
                (selected: Array(self.selections[i] ?? []), text: self.textFields[i]?.text?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard answers.contains(where: { !$0.selected.isEmpty || !($0.text ?? "").isEmpty }) else {
                self.shake(); return
            }
            self.setBusy()
            self.onAnswer?(answers)
        }
        stack.addArrangedSubview(send)
    }

    private func buildSecret(_ r: InputRequest) {
        let s = r.secretRequest
        let name = UILabel()
        name.text = s?.name
        name.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        name.textColor = .secondaryLabel
        stack.addArrangedSubview(name)
        let tf = field(placeholder: s?.placeholder ?? s?.valuePrefix.map { "\($0)…" } ?? "Value")
        tf.isSecureTextEntry = true
        tf.textContentType = .password
        secretField = tf
        stack.addArrangedSubview(tf)
        let note = body("Sent straight to Reason's encrypted store. It never appears in the chat.", size: 12, color: .tertiaryLabel)
        stack.addArrangedSubview(note)
        var buttons: [UIView] = []
        if r.can("secret") {
            buttons.append(primary("Save secret") { [weak self] in
                guard let self, let v = self.secretField?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { self?.shake(); return }
                self.setBusy()
                self.onAction?("secret", v)
            })
        }
        if r.can("cancel") {
            buttons.append(secondary("Decline") { [weak self] in self?.setBusy(); self?.onAction?("cancel", nil) })
        }
        if buttons.isEmpty { buildOpenOnly(r); return }
        stack.addArrangedSubview(row(buttons))
    }

    private func buildApproval(_ r: InputRequest, lines: [String], mono: Bool) {
        if !lines.isEmpty {
            let box = UIStackView()
            box.axis = .vertical
            box.spacing = 4
            for l in lines.prefix(12) {
                let lab = UILabel()
                lab.text = (mono ? "" : "• ") + l
                lab.font = mono ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
                lab.numberOfLines = 0
                box.addArrangedSubview(lab)
            }
            let wrap = UIView()
            wrap.backgroundColor = Theme.groupedBackground
            wrap.layer.cornerRadius = 12
            wrap.addSubview(box)
            box.pin(to: wrap, insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
            stack.addArrangedSubview(wrap)
        }
        guard r.can("approve") || r.can("deny") else { buildOpenOnly(r); return }
        var buttons: [UIView] = []
        if r.can("deny") { buttons.append(secondary("Deny") { [weak self] in self?.setBusy(); self?.onAction?("deny", nil) }) }
        if r.can("approve") { buttons.append(primary("Allow") { [weak self] in self?.setBusy(); self?.onAction?("approve", nil) }) }
        stack.addArrangedSubview(row(buttons))
    }

    private func buildOpenOnly(_ r: InputRequest) {
        guard let s = r.appUrl, let url = URL(string: s) else { return }
        stack.addArrangedSubview(primary("Open in Reason") { [weak self] in self?.onOpen?(url) })
    }

    // MARK: Pieces

    private func body(_ text: String, size: CGFloat = 14, color: UIColor = .secondaryLabel) -> UILabel {
        let l = UILabel()
        l.attributedText = Markdown.render(text, color: color, font: .systemFont(ofSize: size), linkColor: .link)
        l.numberOfLines = 0
        return l
    }

    private func field(placeholder: String) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.font = .systemFont(ofSize: 15)
        tf.backgroundColor = Theme.groupedBackground
        tf.layer.cornerRadius = 12
        tf.layer.cornerCurve = .continuous
        tf.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        tf.leftViewMode = .always
        tf.autocorrectionType = .no
        tf.returnKeyType = .done
        tf.delegate = self
        tf.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return tf
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool { tf.resignFirstResponder(); return true }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        var c = UIButton.Configuration.filled()
        c.title = title
        c.cornerStyle = .capsule
        c.baseBackgroundColor = Theme.mineBubble
        c.baseForegroundColor = Theme.mineText
        c.buttonSize = .medium
        b.configuration = c
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        busyButtons.append(b)
        return b
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        var c = UIButton.Configuration.gray()
        c.title = title
        c.cornerStyle = .capsule
        c.baseForegroundColor = .label
        c.buttonSize = .medium
        b.configuration = c
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        busyButtons.append(b)
        return b
    }

    private func row(_ views: [UIView]) -> UIStackView {
        let r = UIStackView(arrangedSubviews: views)
        r.spacing = 10
        r.distribution = .fillEqually
        return r
    }

    private func setBusy() {
        endEditing(true)
        for b in busyButtons {
            b.isEnabled = false
            var c = b.configuration
            if c?.baseBackgroundColor == Theme.mineBubble { c?.showsActivityIndicator = true }
            b.configuration = c
        }
    }

    /// Re-enable after a failed attempt.
    func resetBusy() {
        for b in busyButtons {
            b.isEnabled = true
            var c = b.configuration
            c?.showsActivityIndicator = false
            b.configuration = c
        }
    }

    func shake() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -9, 8, -5, 3, 0]
        a.duration = 0.4
        card.layer.add(a, forKey: "shake")
    }

    static func symbol(_ type: String) -> String {
        switch type {
        case "question": return "questionmark.bubble"
        case "secret": return "key.fill"
        case "network_hosts": return "network"
        case "permission_rules": return "lock.shield"
        default: return "puzzlepiece.extension"
        }
    }

    static func kicker(_ type: String) -> String {
        switch type {
        case "question": return "QUESTION FOR YOU"
        case "secret": return "SECRET NEEDED"
        case "network_hosts": return "NETWORK ACCESS"
        case "permission_rules": return "PERMISSION CHANGE"
        default: return "ACTION NEEDED"
        }
    }
}

/// Selectable answer option.
final class OptionButton: UIControl {
    let label: String
    private let title = UILabel()
    private let detail = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "circle"))

    init(label: String, detail: String?) {
        self.label = label
        super.init(frame: .zero)
        backgroundColor = Theme.groupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.clear.cgColor
        title.text = label
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.numberOfLines = 0
        self.detail.text = detail
        self.detail.font = .systemFont(ofSize: 12)
        self.detail.textColor = .secondaryLabel
        self.detail.numberOfLines = 0
        self.detail.isHidden = (detail ?? "").isEmpty
        check.tintColor = .tertiaryLabel
        check.setContentHuggingPriority(.required, for: .horizontal)
        let texts = UIStackView(arrangedSubviews: [title, self.detail])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [texts, check])
        row.spacing = 10
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        accessibilityLabel = label
        accessibilityTraits = .button
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool) {
        check.image = UIImage(systemName: on ? "checkmark.circle.fill" : "circle")
        check.tintColor = on ? .label : .tertiaryLabel
        layer.borderColor = (on ? UIColor.label : .clear).resolvedColor(with: traitCollection).cgColor
        accessibilityTraits = on ? [.button, .selected] : .button
        if on { check.addSymbolEffect(.bounce) }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }
}
