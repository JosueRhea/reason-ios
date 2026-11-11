import UIKit

enum Theme {
    static let bodyFont = UIFont.systemFont(ofSize: 16, weight: .regular)

    /// Desktop palette: paper white, soft gray agent bubbles, ink user bubbles.
    static let background = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.035, alpha: 1) : .white }
    static let mineBubble = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1) }
    static let mineText = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.06, alpha: 1) : .white }
    static let theirsBubble = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(red: 0.945, green: 0.945, blue: 0.955, alpha: 1) }
    static let theirsText = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) }
    static let failedBubble = UIColor.systemRed.withAlphaComponent(0.10)
    static let card = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.09, alpha: 1) : .white }
    static let cardStroke = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.08) }
    static let groupedBackground = UIColor { $0.userInterfaceStyle == .dark ? .black : UIColor(red: 0.975, green: 0.975, blue: 0.98, alpha: 1) }

    static func shadow(_ l: CALayer, radius: CGFloat = 12, opacity: Float = 0.08, y: CGFloat = 4) {
        l.shadowColor = UIColor.black.cgColor
        l.shadowOpacity = opacity
        l.shadowRadius = radius
        l.shadowOffset = CGSize(width: 0, height: y)
    }

    static let reasonColorNames = ["black", "blue", "orange", "green", "purple", "red", "teal", "pink", "amber", "brown", "grey", "white"]
    static let eyeStyles = ["pills", "dots", "small", "wide", "sleepy", "brows"]

    static func reasonColor(_ name: String?) -> UIColor {
        switch name?.lowercased() {
        case "amber", "yellow": return UIColor(red: 0.98, green: 0.73, blue: 0.10, alpha: 1)
        case "blue": return UIColor(red: 0.23, green: 0.38, blue: 0.90, alpha: 1)
        case "red": return UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        case "green": return UIColor(red: 0.19, green: 0.64, blue: 0.42, alpha: 1)
        case "purple", "violet": return UIColor(red: 0.56, green: 0.31, blue: 0.78, alpha: 1)
        case "pink": return UIColor(red: 0.84, green: 0.25, blue: 0.62, alpha: 1)
        case "teal", "cyan": return UIColor(red: 0.07, green: 0.65, blue: 0.58, alpha: 1)
        case "orange": return UIColor(red: 0.97, green: 0.42, blue: 0.08, alpha: 1)
        case "gray", "grey", "slate": return UIColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
        case "brown": return UIColor(red: 0.55, green: 0.38, blue: 0.26, alpha: 1)
        case "white": return UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.97, alpha: 1) }
        default: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.07, alpha: 1) }
        }
    }

    static let spring = UISpringTimingParameters(dampingRatio: 0.78, initialVelocity: .zero)
}

extension UIView {
    func pin(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// A symbol in a fixed square box: never squashed by a stack view, always centred on the text line.
final class SymbolBox: UIView {
    let imageView = UIImageView()
    private let side: CGFloat

    init(_ name: String, size: CGFloat = 16, pointSize: CGFloat = 12, weight: UIImage.SymbolWeight = .semibold, tint: UIColor = .secondaryLabel) {
        side = size
        super.init(frame: .zero)
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        imageView.image = UIImage(systemName: name)
        imageView.tintColor = tint
        imageView.contentMode = .center
        addSubview(imageView)
        imageView.pin(to: self)
        translatesAutoresizingMaskIntoConstraints = false
        let w = widthAnchor.constraint(equalToConstant: size), h = heightAnchor.constraint(equalToConstant: size)
        NSLayoutConstraint.activate([w, h])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    func set(_ name: String, tint: UIColor? = nil) {
        imageView.image = UIImage(systemName: name)
        if let tint { imageView.tintColor = tint }
    }
}

/// Small arc spinner whose layout size is its real size (UIActivityIndicatorView can't shrink).
final class MiniSpinner: UIView {
    private let arc = CAShapeLayer()
    init(size: CGFloat = 12) {
        super.init(frame: .zero)
        arc.fillColor = UIColor.clear.cgColor
        arc.lineWidth = 1.6
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.7
        layer.addSublayer(arc)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        arc.frame = bounds
        arc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
        arc.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0; a.toValue = Double.pi * 2; a.duration = 0.9; a.repeatCount = .infinity
        arc.add(a, forKey: "spin")
    }

    var isSpinning: Bool {
        get { !isHidden }
        set { isHidden = !newValue }
    }
}

extension NSAttributedString {
    /// Whether this text needs more than `lines` lines at `width` (so a "Show more" is honest).
    func exceeds(lines: Int, width: CGFloat, font: UIFont) -> Bool {
        guard width > 0 else { return false }
        let h = boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        return h > font.lineHeight * CGFloat(lines) + 4
    }
}
