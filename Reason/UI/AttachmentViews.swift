import UIKit

/// A file shown on a message: received (signed URL) or our own pending upload (file URL).
struct AttachmentRef: Hashable {
    let id: String
    let name: String
    let contentType: String
    let size: Int64?
    let url: URL?
    let aspect: CGFloat?

    var isImage: Bool { contentType.hasPrefix("image/") }

    init(_ a: Attachment, index: Int) {
        id = a.id ?? "att-\(index)"
        name = a.displayName
        contentType = a.contentType ?? "application/octet-stream"
        size = a.sizeBytes.map { Int64($0) }
        url = a.url.flatMap(URL.init(string:))
        if let w = a.width, let h = a.height, w > 0 { aspect = CGFloat(h / w) } else { aspect = nil }
    }

    init(_ f: LocalFile) {
        id = f.id; name = f.name; contentType = f.contentType; size = f.size; url = f.url; aspect = nil
    }

    var imageRef: Markdown.ImageRef? {
        guard isImage, let url else { return nil }
        return Markdown.ImageRef(url: url, alt: name, aspect: min(max(aspect ?? 0.75, 0.3), 1.6))
    }
}

// MARK: - Composer tile

final class AttachmentTile: UIView {
    let file: LocalFile
    var onRemove: (() -> Void)?
    private let preview = UIImageView()

    init(file: LocalFile) {
        self.file = file
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let isVisual = file.isImage || file.isVideo
        widthAnchor.constraint(equalToConstant: isVisual ? 64 : 150).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true

        if isVisual {
            preview.contentMode = .scaleAspectFill
            preview.clipsToBounds = true
            addSubview(preview)
            preview.pin(to: self)
            if file.isVideo {
                let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
                play.tintColor = .white
                play.translatesAutoresizingMaskIntoConstraints = false
                addSubview(play)
                NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo: centerXAnchor), play.centerYAnchor.constraint(equalTo: centerYAnchor)])
            }
            Task { [weak self] in
                let img = await file.thumbnail(maxPixel: 200)
                guard let self else { return }
                UIView.transition(with: self.preview, duration: 0.25, options: .transitionCrossDissolve) { self.preview.image = img }
            }
        } else {
            let icon = UIImageView(image: UIImage(systemName: LocalFile.symbol(for: file.contentType, name: file.name)))
            icon.tintColor = .secondaryLabel
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let name = UILabel()
            name.text = file.name
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            let size = UILabel()
            size.text = LocalFile.formatSize(file.size)
            size.font = .systemFont(ofSize: 11)
            size.textColor = .secondaryLabel
            let texts = UIStackView(arrangedSubviews: [name, size])
            texts.axis = .vertical
            let row = UIStackView(arrangedSubviews: [icon, texts])
            row.spacing = 8
            row.alignment = .center
            addSubview(row)
            row.pin(to: self, insets: UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 22))
        }

        let x = UIButton(type: .system)
        var c = UIButton.Configuration.filled()
        c.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        c.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        c.contentInsets = .zero
        x.configuration = c
        x.accessibilityLabel = "Remove \(file.name)"
        x.translatesAutoresizingMaskIntoConstraints = false
        x.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .touchUpInside)
        addSubview(x)
        NSLayoutConstraint.activate([
            x.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            x.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            x.widthAnchor.constraint(equalToConstant: 18),
            x.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - File card on a message

final class FileCardView: UIControl {
    let ref: AttachmentRef
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(_ ref: AttachmentRef, mine: Bool) {
        self.ref = ref
        super.init(frame: .zero)
        backgroundColor = mine ? Theme.mineBubble : Theme.theirsBubble
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        let fg = mine ? Theme.mineText : Theme.theirsText

        let iconBox = UIView()
        iconBox.backgroundColor = fg.withAlphaComponent(0.1)
        iconBox.layer.cornerRadius = 10
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: LocalFile.symbol(for: ref.contentType, name: ref.name)))
        icon.tintColor = fg
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 40), iconBox.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
        let name = UILabel()
        name.text = ref.name
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.textColor = fg
        name.lineBreakMode = .byTruncatingMiddle
        let meta = UILabel()
        let ext = (ref.name as NSString).pathExtension.uppercased()
        meta.text = [ext.isEmpty ? nil : ext, ref.size.map(LocalFile.formatSize)].compactMap { $0 }.joined(separator: " · ")
        meta.font = .systemFont(ofSize: 12)
        meta.textColor = fg.withAlphaComponent(0.6)
        let texts = UIStackView(arrangedSubviews: [name, meta])
        texts.axis = .vertical
        texts.spacing = 1
        spinner.color = fg
        spinner.hidesWhenStopped = true
        let row = UIStackView(arrangedSubviews: [iconBox, texts, spinner])
        row.spacing = 10
        row.alignment = .center
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 9, left: 9, bottom: 9, right: 14))
        widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ on: Bool) { on ? spinner.startAnimating() : spinner.stopAnimating() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            }
        }
    }
}

// MARK: - Paste images straight into the composer

final class PasteTextView: UITextView {
    var onPasteFiles: (([UIImage]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, let images = pb.images, !images.isEmpty, !pb.hasStrings {
            onPasteFiles?(images)
        } else {
            super.paste(sender)
        }
    }
}
