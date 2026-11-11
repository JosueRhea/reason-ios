import UIKit

/// Create a Reason: name it, dress its avatar, give it standing instructions.
final class NewReasonViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    var onCreated: ((Reason) -> Void)?

    private let app = AppState.shared!
    private var color = Theme.reasonColorNames.filter { $0 != "black" && $0 != "white" }.randomElement() ?? "blue"
    private var eyes = "pills"
    private let preview = AvatarView()
    private let nameField = UITextField()
    private let instructions = UITextView()
    private let placeholder = UILabel()
    private let createButton = UIButton(type: .system)
    private var swatches: [UIButton] = []
    private var eyeButtons: [EyeOption] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Reason"
        view.backgroundColor = Theme.groupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // Preview
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewHolder = UIView()
        previewHolder.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 112), preview.heightAnchor.constraint(equalToConstant: 112),
            preview.centerXAnchor.constraint(equalTo: previewHolder.centerXAnchor),
            preview.topAnchor.constraint(equalTo: previewHolder.topAnchor, constant: 8),
            preview.bottomAnchor.constraint(equalTo: previewHolder.bottomAnchor),
        ])

        // Name
        nameField.placeholder = "Name"
        nameField.font = .systemFont(ofSize: 22, weight: .semibold)
        nameField.textAlignment = .center
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.addAction(UIAction { [weak self] _ in self?.updateCreate() }, for: .editingChanged)

        // Colours
        let colorRow = UIScrollView()
        colorRow.showsHorizontalScrollIndicator = false
        let colorStack = UIStackView()
        colorStack.spacing = 12
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        colorRow.addSubview(colorStack)
        for name in Theme.reasonColorNames {
            let b = UIButton(type: .custom)
            b.backgroundColor = Theme.reasonColor(name)
            b.layer.cornerRadius = 17
            b.layer.borderColor = UIColor.separator.cgColor
            b.layer.borderWidth = name == "white" ? 1 : 0
            b.accessibilityLabel = name.capitalized
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 34), b.heightAnchor.constraint(equalToConstant: 34)])
            b.addAction(UIAction { [weak self] _ in self?.pick(color: name) }, for: .touchUpInside)
            colorStack.addArrangedSubview(b)
            swatches.append(b)
        }
        NSLayoutConstraint.activate([
            colorStack.leadingAnchor.constraint(equalTo: colorRow.contentLayoutGuide.leadingAnchor, constant: 4),
            colorStack.trailingAnchor.constraint(equalTo: colorRow.contentLayoutGuide.trailingAnchor, constant: -4),
            colorStack.topAnchor.constraint(equalTo: colorRow.contentLayoutGuide.topAnchor, constant: 6),
            colorStack.bottomAnchor.constraint(equalTo: colorRow.contentLayoutGuide.bottomAnchor, constant: -6),
            colorRow.heightAnchor.constraint(equalToConstant: 46),
        ])

        // Eyes
        let eyesGrid = UIStackView()
        eyesGrid.distribution = .fillEqually
        eyesGrid.spacing = 8
        for e in Theme.eyeStyles {
            let opt = EyeOption(eyes: e)
            opt.addAction(UIAction { [weak self] _ in self?.pick(eyes: e) }, for: .touchUpInside)
            eyesGrid.addArrangedSubview(opt)
            eyeButtons.append(opt)
        }

        // Instructions
        instructions.font = .systemFont(ofSize: 15)
        instructions.backgroundColor = Theme.card
        instructions.layer.cornerRadius = 16
        instructions.layer.cornerCurve = .continuous
        instructions.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        instructions.delegate = self
        instructions.heightAnchor.constraint(equalToConstant: 120).isActive = true
        placeholder.text = "Instructions (optional): what it's for, how it should work…"
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 2
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        instructions.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: instructions.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: instructions.leadingAnchor, constant: 15),
            placeholder.widthAnchor.constraint(equalTo: instructions.widthAnchor, constant: -30),
        ])

        var cc = UIButton.Configuration.filled()
        cc.title = "Create Reason"
        cc.cornerStyle = .capsule
        cc.buttonSize = .large
        cc.baseBackgroundColor = Theme.mineBubble
        cc.baseForegroundColor = Theme.mineText
        createButton.configuration = cc
        createButton.configurationUpdateHandler = { b in
            var c = b.configuration
            c?.showsActivityIndicator = b.tag == 1
            b.configuration = c
        }
        createButton.addAction(UIAction { [weak self] _ in self?.create() }, for: .touchUpInside)

        [previewHolder, nameField, section("Color", colorRow), section("Eyes", eyesGrid), section("Instructions", instructions), createButton]
            .forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(8, after: previewHolder)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        refresh(animated: false)
        updateCreate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        preview.bounce()
        nameField.becomeFirstResponder()
    }

    private func section(_ title: String, _ content: UIView) -> UIView {
        let l = UILabel()
        l.text = title.uppercased()
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabel
        let s = UIStackView(arrangedSubviews: [l, content])
        s.axis = .vertical
        s.spacing = 8
        return s
    }

    private func pick(color: String) {
        guard color != self.color else { return }
        self.color = color
        UISelectionFeedbackGenerator().selectionChanged()
        refresh(animated: true)
        preview.bounce()
    }

    private func pick(eyes: String) {
        guard eyes != self.eyes else { return }
        self.eyes = eyes
        UISelectionFeedbackGenerator().selectionChanged()
        refresh(animated: true)
        preview.blink()
    }

    private var appearance: Appearance { Appearance(color: color, eyes: eyes, shape: nil) }

    private func refresh(animated: Bool) {
        let apply = {
            self.preview.configure(self.appearance)
            for (i, b) in self.swatches.enumerated() {
                let on = Theme.reasonColorNames[i] == self.color
                b.transform = on ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
                b.layer.borderWidth = on ? 3 : (Theme.reasonColorNames[i] == "white" ? 1 : 0)
                b.layer.borderColor = (on ? UIColor.label : UIColor.separator).resolvedColor(with: self.traitCollection).cgColor
            }
            for b in self.eyeButtons { b.setSelected(b.eyes == self.eyes, color: self.color) }
        }
        animated ? UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, animations: apply) : apply()
    }

    private func updateCreate() {
        createButton.isEnabled = !(nameField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty && createButton.tag == 0
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool { tf.resignFirstResponder(); return true }
    func textViewDidChange(_ tv: UITextView) { placeholder.isHidden = !tv.text.isEmpty }

    private func create() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        createButton.tag = 1
        createButton.setNeedsUpdateConfiguration()
        updateCreate()
        view.endEditing(true)
        let text = instructions.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                var r = try await app.api.createReason(name: name, instructions: text.isEmpty ? nil : text, appearance: appearance)
                if r.appearance == nil { r.appearance = appearance }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                preview.bounce()
                onCreated?(r)
            } catch {
                createButton.tag = 0
                createButton.setNeedsUpdateConfiguration()
                updateCreate()
                let a = UIAlertController(title: "Couldn't create", message: error.localizedDescription, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                present(a, animated: true)
            }
        }
    }
}

/// Mini avatar showing one eye style.
final class EyeOption: UIControl {
    let eyes: String
    private let avatar = AvatarView()
    private let label = UILabel()

    init(eyes: String) {
        self.eyes = eyes
        super.init(frame: .zero)
        avatar.animatesIdle = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        label.text = eyes.capitalized
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        addSubview(label)
        backgroundColor = Theme.card
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 34), avatar.heightAnchor.constraint(equalToConstant: 34),
            label.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        accessibilityLabel = "\(eyes.capitalized) eyes"
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool, color: String) {
        avatar.configure(Appearance(color: color, eyes: eyes, shape: nil))
        layer.borderWidth = on ? 2 : 0
        layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        label.textColor = on ? .label : .secondaryLabel
        transform = on ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}
