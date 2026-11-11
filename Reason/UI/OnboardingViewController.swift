import UIKit

final class OnboardingViewController: UIViewController, UITextFieldDelegate {
    var onConnected: ((AppState) -> Void)?

    private let avatar = AvatarView()
    private let field = UITextField()
    private let button = UIButton(type: .system)
    private let errorLabel = UILabel()
    private var stack: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        avatar.configure(Appearance(color: "black", eyes: "pills", shape: nil))
        avatar.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Reason"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        let subtitle = UILabel()
        subtitle.text = "Paste an API key from Settings → API."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        field.placeholder = "API key"
        field.isSecureTextEntry = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.textContentType = .password
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemBackground
        field.layer.cornerRadius = 14
        field.layer.cornerCurve = .continuous
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.returnKeyType = .go
        field.delegate = self
        field.accessibilityIdentifier = "apiKeyField"
        field.translatesAutoresizingMaskIntoConstraints = false

        var cfg = UIButton.Configuration.filled()
        cfg.title = "Connect"
        cfg.cornerStyle = .large
        cfg.baseBackgroundColor = Theme.mineBubble
        cfg.baseForegroundColor = Theme.mineText
        cfg.buttonSize = .large
        button.configuration = cfg
        button.configurationUpdateHandler = { b in
            var c = b.configuration
            c?.showsActivityIndicator = !b.isEnabled
            c?.title = b.isEnabled ? "Connect" : nil
            b.configuration = c
        }
        button.addTarget(self, action: #selector(connect), for: .touchUpInside)

        let link = UIButton(type: .system)
        var lc = UIButton.Configuration.plain()
        lc.title = "Get a key"
        lc.baseForegroundColor = .secondaryLabel
        link.configuration = lc
        link.addAction(UIAction { _ in UIApplication.shared.open(URL(string: "https://reasonmachines.com/customize?tab=api")!) }, for: .touchUpInside)

        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true

        let holder = UIView()
        holder.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            avatar.topAnchor.constraint(equalTo: holder.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 88),
            avatar.heightAnchor.constraint(equalToConstant: 88),
        ])
        title.textAlignment = .center

        stack = UIStackView(arrangedSubviews: [holder, title, subtitle, field, errorLabel, button, link])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(18, after: holder)
        stack.setCustomSpacing(28, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let centered = stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            field.heightAnchor.constraint(equalToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            centered,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])

        // Entrance
        stack.alpha = 0
        stack.transform = CGAffineTransform(translationX: 0, y: 30)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.stack.alpha = 1
            self.stack.transform = .identity
        }
        avatar.bounce()
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool { connect(); return true }

    @objc private func connect() {
        let key = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { shake(); return }
        button.isEnabled = false
        errorLabel.isHidden = true
        avatar.setThinking(true)
        Task {
            let api = ReasonAPI(apiKey: key)
            do {
                let me = try await api.connect()
                Keychain.save(key)
                DiskCache.save("self", me)
                let state = AppState(api: api)
                state.me = me
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onConnected?(state)
            } catch {
                button.isEnabled = true
                avatar.setThinking(false)
                errorLabel.text = error.localizedDescription
                UIView.animate(withDuration: 0.25) { self.errorLabel.isHidden = false }
                shake()
            }
        }
    }

    private func shake() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -12, 10, -7, 5, -2, 0]
        a.duration = 0.45
        field.layer.add(a, forKey: "shake")
    }
}
