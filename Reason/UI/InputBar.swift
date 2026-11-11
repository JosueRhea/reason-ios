import UIKit
import UniformTypeIdentifiers

protocol InputBarDelegate: AnyObject {
    func inputBarDidSend(_ bar: InputBar, text: String)
    func inputBarDidChangeHeight(_ bar: InputBar)
    func inputBarDidTapModel(_ bar: InputBar)
    func inputBar(_ bar: InputBar, transcribe audio: Data) async throws -> String
}

/// Composer: growing text field in a capsule, iMessage-style send button that springs in,
/// voice dictation with a live waveform, and the model chip underneath.
final class InputBar: UIView, UITextViewDelegate {
    enum Mode { case typing, holding, locked, transcribing }

    weak var delegate: InputBarDelegate?
    var onError: ((String) -> Void)?

    let field = UIView()             // the capsule — also the send animation's origin
    let textView = PasteTextView()
    let plusButton = UIButton(type: .system)
    private let strip = UIScrollView()
    private let stripStack = UIStackView()
    private var stripHeight: NSLayoutConstraint!
    /// Files waiting to go with the next message.
    private(set) var files: [LocalFile] = []
    var onAddFiles: (([LocalFile]) -> Void)?
    let sendButton = UIButton(type: .system)
    let stopButton = UIButton(type: .system)
    let micButton = UIButton(type: .system)
    let modelButton = UIButton(type: .system)
    let effortButton = UIButton(type: .system)
    private let placeholder = UILabel()
    private let backdrop = UIView()
    private let fade = CAGradientLayer()
    private var textHeight: NSLayoutConstraint!
    private var slotWidth: NSLayoutConstraint!
    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 140

    // Recording UI
    private let recordingView = UIView()
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let recDot = UIView()
    private let timeLabel = UILabel()
    private let waveform = WaveformView()
    private let recorder = VoiceRecorder()
    private var meterLink: CADisplayLink?
    private(set) var mode: Mode = .typing

    var isRunning = false { didSet { updateButtons(animated: true) } }

    // MARK: Attachments

    func add(_ new: [LocalFile]) {
        let room = LocalFile.maxCount - files.count
        let accepted = Array(new.prefix(max(0, room)))
        if accepted.count < new.count { onError?("You can attach up to \(LocalFile.maxCount) files.") }
        if let problem = LocalFile.validate(files + accepted) { onError?(problem); return }
        guard !accepted.isEmpty else { return }
        files += accepted
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let showing = stripHeight.constant > 0
        stripHeight.constant = 72
        for f in accepted {
            let tile = AttachmentTile(file: f)
            tile.onRemove = { [weak self, weak tile] in
                guard let self, let tile else { return }
                self.remove(tile)
            }
            tile.alpha = 0
            tile.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            stripStack.addArrangedSubview(tile)
            UIView.animate(withDuration: 0.5, delay: showing ? 0 : 0.08, usingSpringWithDamping: 0.65, initialSpringVelocity: 0) {
                tile.alpha = 1; tile.transform = .identity
            }
        }
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.superview?.layoutIfNeeded()
        }
        DispatchQueue.main.async {
            let x = max(0, self.strip.contentSize.width - self.strip.bounds.width)
            self.strip.setContentOffset(CGPoint(x: x, y: 0), animated: true)
        }
        updateButtons(animated: true)
    }

    private func remove(_ tile: AttachmentTile) {
        files.removeAll { $0.id == tile.file.id }
        UIView.animate(withDuration: 0.25, animations: {
            tile.alpha = 0
            tile.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                tile.isHidden = true
                if self.files.isEmpty { self.stripHeight.constant = 0 }
                self.superview?.layoutIfNeeded()
            } completion: { _ in tile.removeFromSuperview() }
        }
        updateButtons(animated: true)
    }

    /// Takes the files for sending and clears the strip.
    func takeFiles() -> [LocalFile] {
        let out = files
        files = []
        stripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stripHeight.constant = 0
        superview?.layoutIfNeeded()
        updateButtons(animated: true)
        return out
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Content fades out under the composer instead of a hard blur strip.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.isUserInteractionEnabled = false
        backdrop.layer.addSublayer(fade)
        addSubview(backdrop)

        field.backgroundColor = Theme.card
        field.layer.cornerRadius = 24
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1 / UIScreen.main.scale
        field.layer.borderColor = Theme.cardStroke.cgColor
        Theme.shadow(field.layer, radius: 16, opacity: 0.08, y: 4)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        textView.font = Theme.bodyFont
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(textView)

        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        stripStack.spacing = 8
        stripStack.alignment = .center
        stripStack.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(stripStack)
        field.addSubview(strip)
        NSLayoutConstraint.activate([
            stripStack.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor, constant: 10),
            stripStack.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor, constant: -10),
            stripStack.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            stripStack.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            stripStack.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
        ])
        textView.onPasteFiles = { [weak self] images in
            let files = images.enumerated().compactMap { i, img -> LocalFile? in
                guard let data = img.pngData() else { return nil }
                return try? LocalFile.writing(data, name: "Pasted image\(images.count > 1 ? " \(i + 1)" : "").png", type: .png)
            }
            self?.add(files)
        }
        field.addInteraction(UIDropInteraction(delegate: self))

        var plusCfg = UIButton.Configuration.filled()
        plusCfg.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        plusCfg.baseBackgroundColor = .tertiarySystemFill
        plusCfg.baseForegroundColor = .label
        plusCfg.cornerStyle = .capsule
        plusCfg.contentInsets = .zero
        plusButton.configuration = plusCfg
        plusButton.accessibilityLabel = "Attach"
        plusButton.showsMenuAsPrimaryAction = true
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(plusButton)

        placeholder.text = "Message"
        placeholder.font = Theme.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(placeholder)

        Self.circle(sendButton, symbol: "arrow.up", size: 14, bg: Theme.mineBubble, fg: Theme.mineText)
        sendButton.accessibilityLabel = "Send"
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        Self.circle(stopButton, symbol: "stop.fill", size: 11, bg: .secondarySystemFill, fg: .label)
        stopButton.accessibilityLabel = "Stop"

        var micCfg = UIButton.Configuration.filled()
        micCfg.image = UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        micCfg.baseBackgroundColor = .tertiarySystemFill
        micCfg.baseForegroundColor = .secondaryLabel
        micCfg.cornerStyle = .capsule
        micCfg.contentInsets = .zero
        micButton.configuration = micCfg
        micButton.accessibilityLabel = "Dictate"
        micButton.addTarget(self, action: #selector(startRecording), for: .touchUpInside)

        for b in [sendButton, stopButton, micButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(b)
        }

        var mcfg = UIButton.Configuration.plain()
        mcfg.buttonSize = .mini
        mcfg.imagePlacement = .leading
        mcfg.imagePadding = 6
        mcfg.baseForegroundColor = .secondaryLabel
        mcfg.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 6)
        mcfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 4)
        modelButton.configuration = mcfg
        modelButton.accessibilityLabel = "Model"
        modelButton.showsMenuAsPrimaryAction = true
        modelButton.preferredMenuElementOrder = .fixed

        var ecfg = UIButton.Configuration.plain()
        ecfg.buttonSize = .mini
        ecfg.baseForegroundColor = .secondaryLabel
        ecfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        effortButton.configuration = ecfg
        effortButton.accessibilityLabel = "Reasoning effort"
        effortButton.showsMenuAsPrimaryAction = true
        effortButton.preferredMenuElementOrder = .fixed
        effortButton.translatesAutoresizingMaskIntoConstraints = false
        effortButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modelButton)

        setUpRecordingView()

        textHeight = textView.heightAnchor.constraint(equalToConstant: minHeight)
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight.isActive = true
        slotWidth = sendButton.widthAnchor.constraint(equalToConstant: 0)
        modelButton.removeFromSuperview()
        field.addSubview(modelButton)
        field.addSubview(effortButton)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -24),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 120),

            field.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            strip.topAnchor.constraint(equalTo: field.topAnchor, constant: 8),
            strip.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            textView.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: -4),
            textView.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -10),
            textHeight,

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 7),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),

            sendButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 0),
            sendButton.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -8),
            slotWidth,
            sendButton.heightAnchor.constraint(equalToConstant: 32),

            micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            micButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),

            stopButton.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            stopButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 32),
            stopButton.heightAnchor.constraint(equalToConstant: 32),

            plusButton.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 8),
            plusButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 32),
            plusButton.heightAnchor.constraint(equalToConstant: 32),
            modelButton.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 6),
            modelButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            effortButton.leadingAnchor.constraint(equalTo: modelButton.trailingAnchor, constant: 2),
            effortButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            effortButton.trailingAnchor.constraint(lessThanOrEqualTo: micButton.leadingAnchor, constant: -6),
        ])
        updateButtons(animated: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: InputBar, _: UITraitCollection) in v.updateColors() }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        if mode == .typing { field.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor }
        let bg = Theme.background.resolvedColor(with: traitCollection)
        fade.colors = [bg.withAlphaComponent(0).cgColor, bg.withAlphaComponent(0.92).cgColor, bg.cgColor]
        fade.locations = [0, 0.25, 0.45]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hintFade.frame = hintLane.bounds
        fade.frame = backdrop.bounds
        CATransaction.commit()
    }

    private static func circle(_ b: UIButton, symbol: String, size: CGFloat, bg: UIColor, fg: UIColor) {
        var cfg = UIButton.Configuration.filled()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = bg
        cfg.baseForegroundColor = fg
        cfg.contentInsets = .zero
        b.configuration = cfg
    }

    // MARK: Model chip

    func setModel(_ model: ModelsResponse.Model?, effort: String?, fast: Bool) {
        var c = modelButton.configuration
        c?.attributedTitle = Self.chipTitle(model?.displayName ?? "Reason default", weight: .medium, color: .label)
        c?.image = BrandIcon.forModel(model?.id).image(size: 15)
        c?.imageColorTransformer = UIConfigurationColorTransformer { _ in .label }
        modelButton.configuration = c

        var e = effortButton.configuration
        var title = EffortSlider.title(effort)
        if fast && model?.supportsFast == true { title += " ⚡︎" }
        e?.attributedTitle = Self.chipTitle(title, weight: .regular, color: .secondaryLabel)
        effortButton.configuration = e
    }

    /// "Title ⌄" with a small SF chevron, as in the desktop composer.
    private static func chipTitle(_ text: String, weight: UIFont.Weight, color: UIColor) -> AttributedString {
        let s = NSMutableAttributedString(string: text + " ", attributes: [.font: UIFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: color])
        if let chevron = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal) {
            let att = NSTextAttachment(image: chevron)
            att.bounds = CGRect(x: 0, y: 1, width: chevron.size.width, height: chevron.size.height)
            s.append(NSAttributedString(attachment: att))
        }
        return AttributedString(s)
    }

    /// Little hop when the selection changes.
    func pulseModelChip() {
        modelButton.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
            self.modelButton.transform = .identity
        }
    }

    var trimmedText: String { textView.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ tv: UITextView) {
        placeholder.isHidden = !tv.text.isEmpty
        updateButtons(animated: true)
        recalcHeight(animated: true)
    }

    func recalcHeight(animated: Bool) {
        let fit = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let h = min(max(minHeight, fit), maxHeight)
        textView.isScrollEnabled = fit > maxHeight
        guard abs(textHeight.constant - h) > 0.5 else { return }
        textHeight.constant = h
        let work = {
            self.superview?.layoutIfNeeded()
            self.delegate?.inputBarDidChangeHeight(self)
        }
        animated ? UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: work) : work()
    }

    private var sendVisible = false
    private var stopVisible = false
    private var micVisible = false

    private func updateButtons(animated: Bool) {
        let typing = mode == .typing
        let wantSend = typing && (!trimmedText.isEmpty || !files.isEmpty)
        let wantStop = typing && !wantSend && isRunning
        // Stays live during a hold: disabling it would cancel the gesture under the thumb.
        let wantMic = (typing && !wantSend) || mode == .holding
        let slot: CGFloat = (wantSend || wantStop) ? 30 : 0
        if slotWidth.constant != slot {
            slotWidth.constant = slot
            if animated {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                    self.field.layoutIfNeeded()
                }
            }
        }
        pop(sendButton, visible: wantSend, current: &sendVisible, animated: animated)
        pop(stopButton, visible: wantStop, current: &stopVisible, animated: animated)
        pop(micButton, visible: wantMic, current: &micVisible, animated: animated)
    }

    /// The iMessage pop: scale from small with an overshooting spring.
    private func pop(_ b: UIView, visible: Bool, current: inout Bool, animated: Bool) {
        guard visible != current || !animated else { return }
        current = visible
        b.isUserInteractionEnabled = visible
        let apply = {
            b.alpha = visible ? 1 : 0
            b.transform = visible ? .identity : CGAffineTransform(scaleX: 0.3, y: 0.3)
        }
        if !animated { apply(); return }
        UIView.animate(withDuration: visible ? 0.45 : 0.18, delay: 0,
                       usingSpringWithDamping: visible ? 0.55 : 1, initialSpringVelocity: visible ? 6 : 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    @objc private func send() {
        let t = trimmedText
        guard !t.isEmpty || !files.isEmpty else { return }
        delegate?.inputBarDidSend(self, text: t)
    }

    func clear() {
        textView.text = ""
        textViewDidChange(textView)
    }

    // MARK: Voice
    //
    // Hold the mic to talk, release to transcribe. Slide up to lock (hands-free), slide left to
    // cancel. A quick tap starts a locked recording. Discarding drops the red dot into a trash can.

    private let slideHint = UILabel()
    private let hintLane = UIView()        // clips + fades the hint so it never runs into the timer
    private let hintFade = CAGradientLayer()
    private let trashButton = UIButton(type: .system)
    private let holdCircle = UIView()
    private let holdHalo = UIView()
    private let holdIcon = UIImageView(image: UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
    private let lockPill = UIView()
    private let lockIcon = UIImageView(image: UIImage(systemName: "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
    private let lockChevron = UIImageView(image: UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
    private let tip = UILabel()
    private var holdOrigin: CGPoint = .zero
    private var holdStart: Date?
    private var crossedCancelHalf = false
    private let lockDistance: CGFloat = 90
    private let cancelDistance: CGFloat = 130

    private func setUpRecordingView() {
        recordingView.alpha = 0
        recordingView.backgroundColor = Theme.card
        recordingView.layer.cornerRadius = 24
        recordingView.layer.cornerCurve = .continuous
        recordingView.clipsToBounds = true
        recordingView.isHidden = true
        recordingView.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(recordingView)

        var trashCfg = UIButton.Configuration.plain()
        trashCfg.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        trashCfg.baseForegroundColor = .secondaryLabel
        trashCfg.contentInsets = .zero
        trashButton.configuration = trashCfg
        trashButton.accessibilityLabel = "Discard recording"
        trashButton.addAction(UIAction { [weak self] _ in self?.discard() }, for: .touchUpInside)
        // Kept for older call sites (and VoiceOver users): same as the trash.
        cancelButton.isHidden = true

        Self.circle(doneButton, symbol: "arrow.up", size: 14, bg: Theme.mineBubble, fg: Theme.mineText)   // same as Send
        doneButton.accessibilityLabel = "Finish and transcribe"
        doneButton.addTarget(self, action: #selector(finishRecording), for: .touchUpInside)

        recDot.backgroundColor = .systemRed
        recDot.layer.cornerRadius = 5
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.text = "0:00"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        slideHint.text = "‹  Slide to cancel"
        slideHint.font = .systemFont(ofSize: 15, weight: .medium)
        slideHint.textColor = .secondaryLabel
        slideHint.textAlignment = .center

        hintLane.clipsToBounds = true
        hintLane.isUserInteractionEnabled = false
        hintFade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        hintFade.startPoint = CGPoint(x: 0, y: 0.5)
        hintFade.endPoint = CGPoint(x: 1, y: 0.5)
        hintFade.locations = [0, 0.18, 1]
        hintLane.layer.mask = hintFade
        slideHint.translatesAutoresizingMaskIntoConstraints = false
        hintLane.addSubview(slideHint)
        NSLayoutConstraint.activate([
            slideHint.centerXAnchor.constraint(equalTo: hintLane.centerXAnchor),
            slideHint.centerYAnchor.constraint(equalTo: hintLane.centerYAnchor),
        ])
        for v in [trashButton, recDot, timeLabel, waveform, hintLane, doneButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            recordingView.addSubview(v)
        }
        // Same two rows as the composer: a full-width level meter where the text sits, and the
        // controls on the button row, each in the slot its typing counterpart uses.
        let controlsY = recordingView.bottomAnchor   // button row centre = bottom - 24 (8 inset + 32/2)
        NSLayoutConstraint.activate([
            recordingView.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            recordingView.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            recordingView.topAnchor.constraint(equalTo: field.topAnchor),
            recordingView.bottomAnchor.constraint(equalTo: field.bottomAnchor),

            waveform.leadingAnchor.constraint(equalTo: recordingView.leadingAnchor, constant: 18),
            waveform.trailingAnchor.constraint(equalTo: recordingView.trailingAnchor, constant: -18),
            waveform.bottomAnchor.constraint(equalTo: controlsY, constant: -46),
            waveform.heightAnchor.constraint(equalToConstant: 30),

            trashButton.leadingAnchor.constraint(equalTo: recordingView.leadingAnchor, constant: 8),
            trashButton.centerYAnchor.constraint(equalTo: controlsY, constant: -24),
            trashButton.widthAnchor.constraint(equalToConstant: 32),
            trashButton.heightAnchor.constraint(equalToConstant: 32),

            recDot.centerXAnchor.constraint(equalTo: trashButton.centerXAnchor),
            recDot.centerYAnchor.constraint(equalTo: trashButton.centerYAnchor),
            recDot.widthAnchor.constraint(equalToConstant: 10),
            recDot.heightAnchor.constraint(equalToConstant: 10),

            timeLabel.leadingAnchor.constraint(equalTo: trashButton.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: trashButton.centerYAnchor),

            hintLane.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
            hintLane.trailingAnchor.constraint(equalTo: recordingView.trailingAnchor, constant: -56),
            hintLane.centerYAnchor.constraint(equalTo: trashButton.centerYAnchor),
            hintLane.heightAnchor.constraint(equalToConstant: 32),

            doneButton.trailingAnchor.constraint(equalTo: recordingView.trailingAnchor, constant: -8),
            doneButton.centerYAnchor.constraint(equalTo: trashButton.centerYAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 32),
            doneButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Big circle under the thumb while holding, with a halo that breathes with your voice.
        holdHalo.backgroundColor = Theme.mineBubble.withAlphaComponent(0.14)
        holdHalo.layer.cornerRadius = 44
        holdHalo.isUserInteractionEnabled = false
        holdCircle.backgroundColor = Theme.mineBubble
        holdCircle.layer.cornerRadius = 36
        holdCircle.isUserInteractionEnabled = false
        Theme.shadow(holdCircle.layer, radius: 14, opacity: 0.25, y: 4)
        holdIcon.tintColor = Theme.mineText
        holdIcon.contentMode = .center
        holdCircle.addSubview(holdIcon)
        holdIcon.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        holdCircle.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        holdHalo.frame = CGRect(x: 0, y: 0, width: 88, height: 88)
        for v in [holdHalo, holdCircle] { v.alpha = 0; addSubview(v) }

        // Lock pill that rises above the thumb.
        lockPill.backgroundColor = Theme.card
        lockPill.layer.cornerRadius = 20
        lockPill.layer.cornerCurve = .continuous
        lockPill.layer.borderWidth = 1 / UIScreen.main.scale
        lockPill.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor
        Theme.shadow(lockPill.layer, radius: 10, opacity: 0.12, y: 2)
        lockPill.isUserInteractionEnabled = false
        lockPill.frame = CGRect(x: 0, y: 0, width: 40, height: 84)
        lockIcon.tintColor = .label
        lockIcon.contentMode = .center
        lockIcon.frame = CGRect(x: 0, y: 8, width: 40, height: 30)
        lockChevron.tintColor = .tertiaryLabel
        lockChevron.contentMode = .center
        lockChevron.frame = CGRect(x: 0, y: 46, width: 40, height: 24)
        lockPill.addSubview(lockIcon)
        lockPill.addSubview(lockChevron)
        lockPill.alpha = 0
        addSubview(lockPill)

        // Little tip for holds that were too short.
        tip.text = "  Hold to record · Slide up to lock  "
        tip.font = .systemFont(ofSize: 13, weight: .medium)
        tip.textColor = Theme.mineText
        tip.backgroundColor = Theme.mineBubble
        tip.layer.cornerRadius = 14
        tip.clipsToBounds = true
        tip.alpha = 0
        tip.isUserInteractionEnabled = false
        addSubview(tip)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))
        hold.minimumPressDuration = 0.15
        hold.allowableMovement = 1000
        micButton.addGestureRecognizer(hold)
    }

    // MARK: Gesture

    private var micCenter: CGPoint { micButton.superview?.convert(micButton.center, to: self) ?? .zero }

    @objc private func holdChanged(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard mode == .typing else { return }
            guard Permissions.status(.microphone) == .granted else {
                // First time (or switched off): ask / point to Settings, then they hold again.
                Task { _ = await Permissions.ensure(.microphone, from: delegate as? UIViewController) }
                return
            }
            holdOrigin = p
            crossedCancelHalf = false
            guard beginRecording(locked: false) else { return }
            showHoldChrome()
        case .changed:
            guard mode == .holding else { return }
            let dx = min(0, p.x - holdOrigin.x)
            let dy = min(0, p.y - holdOrigin.y)
            // Pick the dominant direction so the circle doesn't wander diagonally.
            let vertical = abs(dy) > abs(dx)
            let lockP = vertical ? min(1, -dy / lockDistance) : 0
            let cancelP = vertical ? 0 : min(1, -dx / cancelDistance)
            let c = micCenter
            holdCircle.center = CGPoint(x: c.x + (vertical ? 0 : dx), y: c.y + (vertical ? dy : 0))
            holdHalo.center = holdCircle.center
            lockPill.center = CGPoint(x: c.x, y: c.y - 96 - lockP * 18)
            lockPill.transform = CGAffineTransform(scaleX: 1 + lockP * 0.08, y: 1 + lockP * 0.08)
            slideHint.transform = CGAffineTransform(translationX: dx * 0.6, y: 0)
            slideHint.alpha = 1 - cancelP * 0.8
            holdCircle.backgroundColor = cancelP > 0.5 ? .systemRed : Theme.mineBubble
            if (cancelP > 0.5) != crossedCancelHalf {
                crossedCancelHalf = cancelP > 0.5
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if lockP >= 1 { lock() } else if cancelP >= 1 { discard() }
        case .ended:
            guard mode == .holding else { return }
            if let start = holdStart, Date().timeIntervalSince(start) < 0.5 {
                discard(quiet: true)
                showTip()
            } else {
                finishRecording()
            }
        case .cancelled, .failed:
            if mode == .holding { discard(quiet: true) }
        default:
            break
        }
    }

    /// Tap the mic: hands-free (locked) recording straight away.
    @objc private func startRecording() {
        guard mode == .typing else { return }
        Task { @MainActor in
            guard await Permissions.ensure(.microphone, from: delegate as? UIViewController) else { return }
            _ = beginRecording(locked: true)
        }
    }

    @discardableResult
    private func beginRecording(locked: Bool) -> Bool {
        do { try recorder.start() } catch { reportError(error.localizedDescription); return false }
        holdStart = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        waveform.reset()
        setMode(locked ? .locked : .holding)
        meterLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(meterTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        meterLink = link
        return true
    }

    private func showHoldChrome() {
        recordingView.layoutIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hintFade.frame = hintLane.bounds
        CATransaction.commit()
        let c = micCenter
        holdCircle.center = c
        holdHalo.center = c
        holdCircle.backgroundColor = Theme.mineBubble
        holdCircle.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        holdHalo.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        lockPill.center = CGPoint(x: c.x, y: c.y - 70)
        lockPill.transform = .identity
        lockIcon.image = UIImage(systemName: "lock.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        lockPill.layer.borderColor = Theme.cardStroke.resolvedColor(with: traitCollection).cgColor
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.58, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.holdCircle.alpha = 1; self.holdHalo.alpha = 1
            self.holdCircle.transform = .identity; self.holdHalo.transform = .identity
            self.lockPill.alpha = 1
            self.lockPill.center = CGPoint(x: c.x, y: c.y - 96)
        }
        // Chevron nudges upward: "this way to lock".
        let nudge = CABasicAnimation(keyPath: "transform.translation.y")
        nudge.fromValue = 4; nudge.toValue = -4
        nudge.duration = 0.6; nudge.autoreverses = true; nudge.repeatCount = .infinity
        nudge.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lockChevron.layer.add(nudge, forKey: "nudge")
        // Slide hint shimmers.
        let shimmer = CABasicAnimation(keyPath: "opacity")
        shimmer.fromValue = 1; shimmer.toValue = 0.45
        shimmer.duration = 0.9; shimmer.autoreverses = true; shimmer.repeatCount = .infinity
        slideHint.layer.add(shimmer, forKey: "shimmer")
    }

    private func hideHoldChrome(locked: Bool) {
        lockChevron.layer.removeAllAnimations()
        slideHint.layer.removeAllAnimations()
        let c = micCenter
        UIView.animate(withDuration: locked ? 0.5 : 0.25, delay: locked ? 0.25 : 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            self.holdCircle.alpha = 0; self.holdHalo.alpha = 0
            self.holdCircle.center = c; self.holdHalo.center = c
            self.holdCircle.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            self.lockPill.alpha = 0
            self.lockPill.center = CGPoint(x: c.x, y: c.y - (locked ? 120 : 70))
            self.slideHint.transform = .identity
        }
    }

    /// Slid far enough up: hands-free from here.
    private func lock() {
        guard mode == .holding else { return }
        lockIcon.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        lockIcon.addSymbolEffect(.bounce)
        lockPill.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        setMode(.locked)
        hideHoldChrome(locked: true)
    }

    @objc private func meterTick() {
        guard recorder.isRecording else {
            if mode == .holding || mode == .locked { finishRecording() }   // hit the max duration
            return
        }
        let level = recorder.level()
        waveform.push(level)
        holdHalo.transform = CGAffineTransform(scaleX: 1 + level * 0.55, y: 1 + level * 0.55)
        let t = Int(recorder.currentTime)
        let text = String(format: "%d:%02d", t / 60, t % 60)
        if timeLabel.text != text { timeLabel.text = text }
    }

    @objc private func cancelRecording() { discard() }

    /// Throw it away: the red dot hops into a trash can that wobbles shut.
    private func discard(quiet: Bool = false) {
        guard mode == .holding || mode == .locked else { return }
        meterLink?.invalidate(); meterLink = nil
        recorder.cancel()
        hideHoldChrome(locked: false)
        if quiet { setMode(.typing); return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        // The recording itself sweeps into the trash; no red dot riding on top of the can.
        recDot.layer.removeAllAnimations()
        recDot.alpha = 0
        doneButton.isEnabled = false
        let trashCenter = trashButton.center
        let content: [UIView] = [waveform, timeLabel, hintLane]
        trashButton.alpha = 1
        if trashButton.transform != .identity { trashButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6) }
        var c = trashButton.configuration
        c?.baseForegroundColor = .systemRed
        trashButton.configuration = c
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.trashButton.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
            self.doneButton.alpha = 0
            self.doneButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        }
        UIView.animate(withDuration: 0.38, delay: 0.05, options: [.curveEaseIn]) {
            for v in content {
                let dx = trashCenter.x - v.center.x, dy = trashCenter.y - v.center.y
                v.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: 0.05, y: 0.3)
                v.alpha = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Lid snaps shut.
            self.trashButton.imageView?.addSymbolEffect(.bounce)
            let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wobble.values = [0, -0.22, 0.18, -0.1, 0.05, 0]
            wobble.duration = 0.42
            self.trashButton.layer.add(wobble, forKey: "wobble")
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                self.trashButton.transform = .identity
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            var c = self.trashButton.configuration
            c?.baseForegroundColor = .secondaryLabel
            self.trashButton.configuration = c
            self.setMode(.typing)
            // Put the pieces back for next time once the panel has faded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                for v in content { v.transform = .identity; v.alpha = 1 }
            }
        }
    }

    @objc private func finishRecording() {
        guard mode == .holding || mode == .locked else { return }
        meterLink?.invalidate(); meterLink = nil
        hideHoldChrome(locked: false)
        let duration = recorder.currentTime
        guard let audio = recorder.stop(), duration > 0.4 || audio.count > 4000 else { setMode(.typing); return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        setMode(.transcribing)
        Task { @MainActor in
            do {
                let text = try await delegate?.inputBar(self, transcribe: audio) ?? ""
                setMode(.typing)
                insertTranscript(text)
            } catch {
                setMode(.typing)
                reportError(error.localizedDescription)
            }
        }
    }

    private func showTip() {
        let c = micCenter
        tip.sizeToFit()
        tip.frame.size.height = 28
        tip.center = CGPoint(x: min(bounds.width - tip.bounds.width / 2 - 12, c.x - 40), y: c.y - 46)
        tip.transform = CGAffineTransform(translationX: 0, y: 8)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0) {
            self.tip.alpha = 1; self.tip.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 1.8, options: []) { self.tip.alpha = 0 }
    }

    private func setMode(_ m: Mode) {
        mode = m
        let recordingUI = m != .typing
        let holding = m == .holding
        recDot.layer.removeAnimation(forKey: "pulse")
        if m == .holding {   // only while visible: an opacity loop would override the hidden state
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.2
            pulse.duration = 0.7; pulse.autoreverses = true; pulse.repeatCount = .infinity
            recDot.layer.add(pulse, forKey: "pulse")
        }
        if m == .holding { timeLabel.text = "0:00" }
        if m == .transcribing {
            timeLabel.text = "Transcribing"
            waveform.startProcessing()
        } else {
            waveform.stopProcessing()
        }
        doneButton.isEnabled = m == .locked
        trashButton.isEnabled = m == .locked
        updateButtons(animated: true)

        if recordingUI && recordingView.isHidden {
            recordingView.isHidden = false
            recordingView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            recordingView.layoutIfNeeded()
        }
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.recordingView.alpha = recordingUI ? 1 : 0
            for v in [self.plusButton, self.modelButton, self.effortButton, self.strip] as [UIView] { v.alpha = recordingUI ? 0 : 1 }
            self.recordingView.transform = .identity
            self.textView.alpha = recordingUI ? 0 : 1
            self.placeholder.alpha = recordingUI ? 0 : 1
            // Holding: dot + timer + "slide to cancel". Locked: trash + timer + waveform + send.
            self.recDot.alpha = holding ? 1 : 0
            self.recDot.transform = holding ? .identity : CGAffineTransform(scaleX: 0.01, y: 0.01)
            if m != .locked {
                self.trashButton.alpha = 0
                self.trashButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.hintLane.alpha = holding ? 1 : 0
            self.slideHint.alpha = 1
            self.waveform.alpha = 1
            self.doneButton.alpha = m == .locked ? 1 : (m == .transcribing ? 0.3 : 0)
            self.doneButton.transform = m == .locked ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
            self.field.layer.borderColor = Theme.cardStroke.resolvedColor(with: self.traitCollection).cgColor
        } completion: { _ in
            if self.mode == .typing { self.recordingView.isHidden = true }
        }
        if m == .locked {
            // The dot is gone first; then the trash springs into its slot.
            UIView.animate(withDuration: 0.45, delay: 0.12, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                self.trashButton.alpha = 1
                self.trashButton.transform = .identity
            }
        }
    }

    #if DEBUG
    /// Gallery only: show the recording UI without touching the microphone.
    func debugShowRecording(locked: Bool = true) {
        setMode(locked ? .locked : .holding)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for i in 0..<60 { self.waveform.push(CGFloat(abs(sin(Double(i) / 3))) * 0.8) }
            self.timeLabel.text = "0:02"
        }
    }
    #endif

    /// Drop the transcript in with a soft rise, then focus for editing.
    private func insertTranscript(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            reportError("Didn't catch that — try again a little closer to the mic.")
            return
        }
        let existing = textView.text ?? ""
        textView.text = existing.isEmpty ? t : existing + (existing.hasSuffix(" ") ? "" : " ") + t
        textViewDidChange(textView)
        textView.alpha = 0
        textView.transform = CGAffineTransform(translationX: 0, y: 6)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.textView.alpha = 1
            self.textView.transform = .identity
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        textView.becomeFirstResponder()
    }

    private func reportError(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        onError?(message)
    }
}

extension InputBar: UIDropInteractionDelegate {
    func dropInteraction(_ i: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: ["public.item"])
    }
    func dropInteraction(_ i: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }
    func dropInteraction(_ i: UIDropInteraction, performDrop session: UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        Task { @MainActor in
            let r = await ItemImporter.load(providers)
            self.add(r.files)
            if !r.texts.isEmpty {
                self.textView.text = ([self.textView.text ?? ""] + r.texts).filter { !$0.isEmpty }.joined(separator: "\n")
                self.textViewDidChange(self.textView)
            }
        }
    }
}
