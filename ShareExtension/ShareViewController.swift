import UIKit
import UniformTypeIdentifiers

/// Share sheet: pick a Reason, add a note, send the shared files/links/text as one message.
final class ShareViewController: UIViewController, UITextViewDelegate {
    private let dim = UIView()
    private let card = UIView()
    private let cancelButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let reasonsScroll = UIScrollView()
    private let reasonsStack = UIStackView()
    private let filesScroll = UIScrollView()
    private let filesStack = UIStackView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let status = UILabel()
    private var cardBottom: NSLayoutConstraint!

    private var api: ReasonAPI?
    private var reasons: [Reason] = []
    private var selectedId: String?
    private var files: [LocalFile] = []
    private var sending = false
    private let defaults = UserDefaults(suiteName: Keychain.appGroup)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        dim.alpha = 0
        view.addSubview(dim)
        dim.pin(to: view)
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cancel)))
        buildCard()
        loadShared()
        connect()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Card rises with a spring, like iMessage's compose sheet.
        cardBottom.constant = 0
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
            self.dim.alpha = 1
            self.view.layoutIfNeeded()
        }
        textView.becomeFirstResponder()
    }

    // MARK: Layout

    private func buildCard() {
        card.backgroundColor = Theme.card
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        Theme.shadow(card.layer, radius: 24, opacity: 0.15, y: -2)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        var cc = UIButton.Configuration.plain()
        cc.title = "Cancel"
        cc.baseForegroundColor = .secondaryLabel
        cancelButton.configuration = cc
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        var sc = UIButton.Configuration.filled()
        sc.title = "Send"
        sc.cornerStyle = .capsule
        sc.baseBackgroundColor = Theme.mineBubble
        sc.baseForegroundColor = Theme.mineText
        sc.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        sendButton.configuration = sc
        sendButton.isEnabled = false
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)

        titleLabel.text = "Send to Reason"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textAlignment = .center
        let header = UIStackView(arrangedSubviews: [cancelButton, titleLabel, sendButton])
        header.alignment = .center
        header.distribution = .equalCentering

        reasonsScroll.showsHorizontalScrollIndicator = false
        reasonsStack.spacing = 14
        reasonsStack.translatesAutoresizingMaskIntoConstraints = false
        reasonsScroll.addSubview(reasonsStack)
        let loading = UIActivityIndicatorView(style: .medium)
        loading.startAnimating()
        reasonsStack.addArrangedSubview(loading)

        filesScroll.showsHorizontalScrollIndicator = false
        filesStack.spacing = 8
        filesStack.alignment = .center
        filesStack.translatesAutoresizingMaskIntoConstraints = false
        filesScroll.addSubview(filesStack)
        filesScroll.isHidden = true

        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = Theme.groupedBackground
        textView.layer.cornerRadius = 16
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 10, bottom: 11, right: 10)
        textView.delegate = self
        placeholder.text = "Add a message"
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.textAlignment = .center
        status.isHidden = true

        let stack = UIStackView(arrangedSubviews: [header, reasonsScroll, filesScroll, textView, status])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        cardBottom = card.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: 600)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardBottom,
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),

            reasonsStack.leadingAnchor.constraint(equalTo: reasonsScroll.contentLayoutGuide.leadingAnchor, constant: 2),
            reasonsStack.trailingAnchor.constraint(equalTo: reasonsScroll.contentLayoutGuide.trailingAnchor, constant: -2),
            reasonsStack.topAnchor.constraint(equalTo: reasonsScroll.contentLayoutGuide.topAnchor),
            reasonsStack.bottomAnchor.constraint(equalTo: reasonsScroll.contentLayoutGuide.bottomAnchor),
            reasonsStack.heightAnchor.constraint(equalTo: reasonsScroll.frameLayoutGuide.heightAnchor),
            reasonsScroll.heightAnchor.constraint(equalToConstant: 78),

            filesStack.leadingAnchor.constraint(equalTo: filesScroll.contentLayoutGuide.leadingAnchor),
            filesStack.trailingAnchor.constraint(equalTo: filesScroll.contentLayoutGuide.trailingAnchor),
            filesStack.topAnchor.constraint(equalTo: filesScroll.contentLayoutGuide.topAnchor),
            filesStack.bottomAnchor.constraint(equalTo: filesScroll.contentLayoutGuide.bottomAnchor),
            filesStack.heightAnchor.constraint(equalTo: filesScroll.frameLayoutGuide.heightAnchor),
            filesScroll.heightAnchor.constraint(equalToConstant: 64),

            textView.heightAnchor.constraint(equalToConstant: 96),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 11),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 15),
        ])
    }

    func textViewDidChange(_ tv: UITextView) {
        placeholder.isHidden = !tv.text.isEmpty
        updateSendEnabled()
    }

    private func updateSendEnabled() {
        let hasContent = !files.isEmpty || !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = !sending && selectedId != nil && api != nil && hasContent
    }

    // MARK: Data

    private func loadShared() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { @MainActor [weak self] in
            let r = await ItemImporter.load(providers)
            guard let self else { return }
            if let problem = LocalFile.validate(r.files) { showStatus(problem, error: true) }
            files = Array(r.files.prefix(LocalFile.maxCount))
            if !r.texts.isEmpty {
                textView.text = r.texts.joined(separator: "\n")
                textViewDidChange(textView)
            }
            filesScroll.isHidden = files.isEmpty
            for f in files {
                let tile = AttachmentTile(file: f)
                tile.onRemove = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    self.files.removeAll { $0.id == tile.file.id }
                    UIView.animate(withDuration: 0.3) {
                        tile.isHidden = true
                        tile.alpha = 0
                        self.filesScroll.isHidden = self.files.isEmpty
                    } completion: { _ in tile.removeFromSuperview() }
                    self.updateSendEnabled()
                }
                filesStack.addArrangedSubview(tile)
            }
            updateSendEnabled()
        }
    }

    private func connect() {
        guard let key = Keychain.load() else {
            showStatus("Open Reason and sign in first.", error: true)
            reasonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        let api = ReasonAPI(apiKey: key)
        Task { @MainActor in
            do {
                try await api.connect()
                let list = try await api.reasons()
                self.api = api
                self.reasons = list
                let last = defaults?.string(forKey: "share.lastReason")
                selectedId = list.first { $0.id == last }?.id ?? list.first { $0.main == true }?.id ?? list.first?.id
                buildReasons()
                updateSendEnabled()
            } catch {
                showStatus(error.localizedDescription, error: true)
            }
        }
    }

    private func buildReasons() {
        reasonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in reasons {
            let chip = ReasonPickChip(reason: r)
            chip.isSelected = r.id == selectedId
            chip.addAction(UIAction { [weak self] _ in self?.select(r.id) }, for: .touchUpInside)
            reasonsStack.addArrangedSubview(chip)
        }
    }

    private func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        UISelectionFeedbackGenerator().selectionChanged()
        for case let chip as ReasonPickChip in reasonsStack.arrangedSubviews { chip.isSelected = chip.reason.id == id }
        updateSendEnabled()
    }

    // MARK: Actions

    @objc private func cancel() {
        guard !sending else { return }
        dismissCard { self.extensionContext?.cancelRequest(withError: NSError(domain: "ReasonShare", code: 0)) }
    }

    @objc private func send() {
        guard let api, let rid = selectedId else { return }
        sending = true
        updateSendEnabled()
        var c = sendButton.configuration
        c?.showsActivityIndicator = true
        c?.title = nil
        sendButton.configuration = c
        textView.resignFirstResponder()
        let typed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = !typed.isEmpty ? typed : (files.count == 1 ? "Attached \(files[0].name)" : "Attached \(files.count) files")
        if !files.isEmpty { showStatus("Sending \(files.count) file\(files.count == 1 ? "" : "s") · \(LocalFile.formatSize(files.reduce(0) { $0 + $1.size }))", error: false) }
        Task { @MainActor in
            do {
                _ = try await api.sendReasonMessage(rid, text: text, clientId: "share-" + UUID().uuidString,
                                                    model: nil, effort: nil, speed: nil, files: files)
                defaults?.set(rid, forKey: "share.lastReason")
                succeed()
            } catch {
                sending = false
                var c = sendButton.configuration
                c?.showsActivityIndicator = false
                c?.title = "Send"
                sendButton.configuration = c
                updateSendEnabled()
                showStatus(error.localizedDescription, error: true)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                a.values = [0, -10, 9, -6, 4, 0]
                a.duration = 0.4
                card.layer.add(a, forKey: "shake")
            }
        }
    }

    private func succeed() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        var c = sendButton.configuration
        c?.showsActivityIndicator = false
        c?.title = nil
        c?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        sendButton.configuration = c
        sendButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
            self.sendButton.transform = .identity
        }
        showStatus("Sent", error: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.dismissCard { self.extensionContext?.completeRequest(returningItems: nil) }
        }
    }

    private func dismissCard(_ then: @escaping () -> Void) {
        view.endEditing(true)
        cardBottom.constant = card.bounds.height + 80
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseIn]) {
            self.dim.alpha = 0
            self.view.layoutIfNeeded()
        } completion: { _ in then() }
    }

    private func showStatus(_ text: String, error: Bool) {
        status.text = text
        status.textColor = error ? .systemRed : .secondaryLabel
        UIView.animate(withDuration: 0.25) { self.status.isHidden = false }
    }
}

/// Avatar + name; selected gets a ring and a little pop.
final class ReasonPickChip: UIControl {
    let reason: Reason
    private let avatar = AvatarView()
    private let ring = UIView()
    private let name = UILabel()

    init(reason: Reason) {
        self.reason = reason
        super.init(frame: .zero)
        ring.layer.cornerRadius = 27
        ring.layer.borderWidth = 2
        ring.isUserInteractionEnabled = false
        ring.translatesAutoresizingMaskIntoConstraints = false
        avatar.configure(reason.appearance)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        name.text = reason.name
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textAlignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        [ring, avatar, name].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 54), ring.heightAnchor.constraint(equalToConstant: 54),
            avatar.centerXAnchor.constraint(equalTo: ring.centerXAnchor), avatar.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 44), avatar.heightAnchor.constraint(equalToConstant: 44),
            name.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: leadingAnchor), name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isSelected = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet {
            ring.layer.borderColor = (isSelected ? UIColor.label : UIColor.clear).resolvedColor(with: traitCollection).cgColor
            name.textColor = isSelected ? .label : .secondaryLabel
            if isSelected && oldValue != isSelected { avatar.bounce() }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.avatar.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }
}
