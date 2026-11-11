import UIKit

/// Draws parsed markdown as a stack: text runs in labels, code in scrollable highlighted blocks,
/// tables as scrollable grids, quotes with a bar, rules as hairlines.
final class MarkdownView: UIView, UIGestureRecognizerDelegate {
    private let stack = UIStackView()
    private var blocks: [MDBlock] = []
    private var font: UIFont = Theme.bodyFont
    private var linkTint: UIColor = .link
    var onLinkTap: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        addSubview(stack)
        stack.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Text views, in order, for link hit-testing and the favicon refresh.
    private(set) var labels: [RichTextView] = []

    /// The width this view will be laid out at, so text can measure before the first layout pass.
    var widthHint: CGFloat = 0 {
        didSet {
            guard widthHint != oldValue else { return }
            for l in labels { l.widthHint = l.superview is QuoteView ? widthHint - QuoteView.inset : widthHint }
        }
    }

    func configure(_ blocks: [MDBlock], font: UIFont = Theme.bodyFont, linkTint: UIColor = .link) {
        self.font = font
        self.linkTint = linkTint
        if blocks == self.blocks {
            refreshLinks()
            return
        }
        self.blocks = blocks
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        labels = []
        var prev: MDBlock?
        for b in blocks {
            let v: UIView
            switch b {
            case .text(let s):
                v = makeLabel(s)
            case .quote(let s):
                v = QuoteView(label: makeLabel(s, inset: QuoteView.inset))
            case .code(let lang, let code):
                v = CodeBlockView(code: code, lang: lang)
            case .table(let h, let rows, let align):
                v = TableBlockView(header: h, rows: rows, align: align)
            case .rule:
                let line = UIView()
                line.backgroundColor = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                let wrap = UIView()
                wrap.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor), line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                    line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4), line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
                ])
                v = wrap
            }
            if let last = stack.arrangedSubviews.last, let prev {
                // Text followed by a code block reads as one thought: tighter.
                if case .text = prev, case .code = b { stack.setCustomSpacing(8, after: last) }
            }
            stack.addArrangedSubview(v)
            prev = b
        }
    }

    private func makeLabel(_ s: NSAttributedString, inset: CGFloat = 0) -> RichTextView {
        let l = RichTextView()
        l.widthHint = widthHint > 0 ? widthHint - inset : 0
        l.attributedText = Favicons.decorate(s, font: font, tint: linkTint)
        let g = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        g.delegate = self
        l.addGestureRecognizer(g)
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        labels.append(l)
        objc_setAssociatedObject(l, &MarkdownView.sourceKey, s, .OBJC_ASSOCIATION_RETAIN)
        return l
    }

    private static var sourceKey: UInt8 = 0

    /// Re-decorates links (favicons that arrived since).
    private func refreshLinks() {
        for l in labels {
            if let s = objc_getAssociatedObject(l, &MarkdownView.sourceKey) as? NSAttributedString {
                let d = Favicons.decorate(s, font: font, tint: linkTint)
                if !(l.attributedText?.isEqual(to: d) ?? false) { l.attributedText = d }
            }
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let l = g.view as? RichTextView, let url = l.link(at: g.location(in: l)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onLinkTap?(url)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let l = g.view as? RichTextView, labels.contains(l) else { return super.gestureRecognizerShouldBegin(g) }
        return l.link(at: g.location(in: l)) != nil
    }
}

// MARK: - Quote

private final class QuoteView: UIView {
    static let inset: CGFloat = 17
    init(label: UIView) {
        super.init(frame: .zero)
        let bar = UIView()
        bar.backgroundColor = UIColor.label.withAlphaComponent(0.16)
        bar.layer.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(label)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bar.widthAnchor.constraint(equalToConstant: 3),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Code block

/// Highlighted code on a soft panel: language and a Copy button on top, long lines scroll sideways.
final class CodeBlockView: UIView {
    static let fill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(red: 0.965, green: 0.965, blue: 0.97, alpha: 1) }
    private let code: String
    private let copy = UIButton(type: .system)

    init(code: String, lang: String?) {
        self.code = code
        super.init(frame: .zero)
        backgroundColor = Self.fill
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let langLabel = UILabel()
        langLabel.text = Self.displayName(lang)
        langLabel.font = .systemFont(ofSize: 12, weight: .medium)
        langLabel.textColor = .secondaryLabel

        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        c.baseForegroundColor = .secondaryLabel
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        copy.configuration = c
        copy.accessibilityLabel = "Copy code"
        copy.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .touchUpInside)

        let top = UIStackView(arrangedSubviews: [langLabel, UIView(), copy])
        top.alignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false

        let mono = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let text = NSMutableAttributedString(attributedString: SyntaxHighlight.highlight(code, lang: lang, font: mono))
        let p = NSMutableParagraphStyle(); p.lineSpacing = 3
        text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: text.length))
        let label = RichTextView(wraps: false)
        label.attributedText = text
        label.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)

        addSubview(top)
        addSubview(scroll)
        let size = label.naturalSize
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 0),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: ceil(size.height)),

            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(equalToConstant: ceil(size.width) + 1),
            label.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func copyCode() {
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copy.configuration?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copy.configuration?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
    }

    static func displayName(_ lang: String?) -> String {
        guard let l = lang?.lowercased(), !l.isEmpty else { return "Code" }
        let names = ["sh": "Shell", "bash": "Bash", "zsh": "Zsh", "shell": "Shell", "console": "Console", "js": "JavaScript",
                     "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX", "jsx": "JSX",
                     "py": "Python", "python": "Python", "swift": "Swift", "rs": "Rust", "rust": "Rust", "go": "Go",
                     "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "sql": "SQL", "html": "HTML", "css": "CSS",
                     "diff": "Diff", "md": "Markdown", "markdown": "Markdown", "rb": "Ruby", "ruby": "Ruby", "kt": "Kotlin",
                     "kotlin": "Kotlin", "java": "Java", "c": "C", "cpp": "C++", "c++": "C++", "text": "Text", "txt": "Text"]
        return names[l] ?? l.capitalized
    }
}

// MARK: - Table

/// A grid with a bold header row and hairline row separators; wide tables scroll sideways.
private final class TableBlockView: UIView {
    init(header: [NSAttributedString], rows: [[NSAttributedString]], align: [NSTextAlignment]) {
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: TableBlockView, _: UITraitCollection) in
            v.layer.borderColor = UIColor.separator.resolvedColor(with: v.traitCollection).cgColor
        }

        let n = header.count
        let padX: CGFloat = 12, padY: CGFloat = 8, maxCol: CGFloat = 240
        // Column widths from content, capped so long cells wrap.
        var widths = [CGFloat](repeating: 40, count: n)
        for r in [header] + rows {
            for (c, s) in r.enumerated() where c < n {
                let w = s.boundingRect(with: CGSize(width: maxCol, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).width
                widths[c] = min(maxCol, max(widths[c], ceil(w)))
            }
        }
        let grid = UIStackView()
        grid.axis = .vertical
        grid.translatesAutoresizingMaskIntoConstraints = false
        for (ri, r) in ([header] + rows).enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            for c in 0..<n {
                let l = UILabel()
                l.numberOfLines = 0
                l.attributedText = c < r.count ? r[c] : nil
                l.textAlignment = align[c]
                l.translatesAutoresizingMaskIntoConstraints = false
                let cell = UIView()
                cell.addSubview(l)
                NSLayoutConstraint.activate([
                    l.topAnchor.constraint(equalTo: cell.topAnchor, constant: padY),
                    l.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -padY),
                    l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: padX),
                    l.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -padX),
                    l.widthAnchor.constraint(equalToConstant: widths[c]),
                ])
                row.addArrangedSubview(cell)
            }
            row.addArrangedSubview(UIView())     // spare width when the table is narrower than the column
            if ri == 0 { row.backgroundColor = UIColor.label.withAlphaComponent(0.04) }
            grid.addArrangedSubview(row)
            if ri < rows.count {
                let line = UIView()
                line.backgroundColor = .separator
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                grid.addArrangedSubview(line)
            }
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(grid)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            grid.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: grid.heightAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Selectable text

/// Read-only text you can select like a document: hold to select, drag the handles, Copy / Look Up / Share.
/// Sizes itself to its text, like a multi-line label. TextKit 1, so link hit-testing can use its layout.
final class SelectableTextView: UITextView {
    init() {
        let storage = NSTextStorage()
        let layout = PillBackgroundLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        dataDetectorTypes = []
        tintColor = .link
        textDragInteraction?.isEnabled = false
        setContentCompressionResistancePriority(.required, for: .vertical)
        // Our own link handling (in-app sessions, favicons); the text view must not open links itself.
        linkTextAttributes = [:]
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The link (`attachmentLinkKey`) under a point, including the favicon in front of it.
    func link(at point: CGPoint) -> URL? {
        guard let text = attributedText, text.length > 0 else { return nil }
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -4, dy: -4).contains(p) else { return nil }
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        guard char < text.length else { return nil }
        for i in [char, min(char + 1, text.length - 1), min(char + 2, text.length - 1)] {
            if let url = text.attribute(.attachmentLinkKey, at: i, effectiveRange: nil) as? URL { return url }
            if i == char, text.attribute(.attachment, at: i, effectiveRange: nil) == nil { break }
        }
        return nil
    }

    /// Clear the selection when the cell is reused or the text changes underneath it.
    override var attributedText: NSAttributedString! {
        didSet { selectedRange = NSRange(location: 0, length: 0) }
    }
}

/// Draws text backgrounds (inline code) as rounded pills hugging the glyphs, per line, instead of
/// TextKit's square fill that runs into the indent and out to the line's end when the code wraps.
final class PillBackgroundLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: UIColor) {
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard let ctx = UIGraphicsGetCurrentContext(), let storage = textStorage else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color); return
        }
        let text = storage.string as NSString
        ctx.saveGState()
        color.setFill()
        enumerateLineFragments(forGlyphRange: glyphs) { _, _, container, lineGlyphs, _ in
            var r = NSIntersectionRange(lineGlyphs, glyphs)
            // Leave out whitespace at either end of the line piece.
            while r.length > 0, let c = Self.char(text, self.characterIndexForGlyph(at: NSMaxRange(r) - 1)), c.isWhitespace, c != "\u{202F}" { r.length -= 1 }
            while r.length > 0, let c = Self.char(text, self.characterIndexForGlyph(at: r.location)), c.isWhitespace, c != "\u{202F}" { r.location += 1; r.length -= 1 }
            guard r.length > 0 else { return }
            var b = self.boundingRect(forGlyphRange: r, in: container)
            // Line spacing sits below the glyphs; keep the pill on the text.
            if let p = storage.attribute(.paragraphStyle, at: self.characterIndexForGlyph(at: r.location), effectiveRange: nil) as? NSParagraphStyle {
                b.size.height -= p.lineSpacing
            }
            b = b.insetBy(dx: 0, dy: 0.5)
            UIBezierPath(roundedRect: b, cornerRadius: 4.5).fill()
        }
        ctx.restoreGState()
    }

    private static func char(_ s: NSString, _ i: Int) -> Character? {
        guard i < s.length, let u = Unicode.Scalar(s.character(at: i)) else { return nil }
        return Character(u)
    }
}

// MARK: - Drawn text

/// Fast, drawn text (TextKit 1, measured once per width): what replies display. Holding on it swaps in a
/// selectable text view over the same layout for as long as you're selecting.
final class RichTextView: UIView, UITextViewDelegate {
    private let storage = NSTextStorage()
    let layoutManager = PillBackgroundLayoutManager()
    let container = NSTextContainer()
    let wraps: Bool
    private var heights: [CGFloat: CGFloat] = [:]
    private var lastWidth: CGFloat = -1
    private var selecting: SelectableTextView?

    var attributedText: NSAttributedString? {
        didSet {
            storage.setAttributedString(attributedText ?? NSAttributedString())
            heights = [:]
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// Width to measure at before the first layout (the cell knows it; the view doesn't yet).
    var widthHint: CGFloat = 0 { didSet { if widthHint != oldValue { invalidateIntrinsicContentSize() } } }

    init(wraps: Bool = true) {
        self.wraps = wraps
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        container.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        // Record drawing commands and rasterize off the main thread: tall replies otherwise cost a
        // full-height bitmap paint on the frame the chat opens.
        layer.drawsAsynchronously = true
        setContentCompressionResistancePriority(.required, for: .vertical)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout(width: CGFloat) {
        let w = wraps ? width : CGFloat.greatestFiniteMagnitude
        if container.size.width != w { container.size = CGSize(width: w, height: .greatestFiniteMagnitude) }
    }

    func height(for width: CGFloat) -> CGFloat {
        if let h = heights[width] { return h }
        layout(width: width)
        layoutManager.ensureLayout(for: container)
        let h = ceil(layoutManager.usedRect(for: container).height)
        heights[width] = h
        return h
    }

    /// Unwrapped size (code).
    var naturalSize: CGSize {
        layout(width: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let r = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    override var intrinsicContentSize: CGSize {
        guard wraps else { return naturalSize }
        let w = widthHint > 0 ? widthHint : bounds.width
        guard w > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 20) }
        return CGSize(width: UIView.noIntrinsicMetric, height: height(for: w))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            if wraps, widthHint != bounds.width, bounds.width > 0 { widthHint = 0; invalidateIntrinsicContentSize() }
            setNeedsDisplay()
        }
        selecting?.frame = bounds
    }

    override func draw(_ rect: CGRect) {
        guard selecting == nil else { return }
        layout(width: bounds.width)
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// The link (`attachmentLinkKey`) under a point, including the favicon in front of it.
    func link(at p: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        layout(width: bounds.width)
        let glyph = layoutManager.glyphIndex(for: p, in: container)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -4, dy: -4).contains(p) else { return nil }
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        guard char < storage.length else { return nil }
        for i in [char, min(char + 1, storage.length - 1), min(char + 2, storage.length - 1)] {
            if let url = storage.attribute(.attachmentLinkKey, at: i, effectiveRange: nil) as? URL { return url }
            if i == char, storage.attribute(.attachment, at: i, effectiveRange: nil) == nil { break }
        }
        return nil
    }

    // MARK: Selection

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, selecting == nil, let text = attributedText else { return }
        let tv = SelectableTextView()
        if !wraps {
            tv.textContainer.lineBreakMode = .byClipping
            tv.textContainer.widthTracksTextView = false
            tv.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        tv.attributedText = text
        tv.frame = bounds
        tv.delegate = self
        addSubview(tv)
        selecting = tv
        setNeedsDisplay()
        let p = g.location(in: tv)
        tv.becomeFirstResponder()
        if let pos = tv.closestPosition(to: p),
           let r = tv.tokenizer.rangeEnclosingPosition(pos, with: .word, inDirection: .storage(.forward))
                ?? tv.tokenizer.rangeEnclosingPosition(pos, with: .word, inDirection: .storage(.backward)) {
            tv.selectedTextRange = r
        }
        UISelectionFeedbackGenerator().selectionChanged()
        let menu = UIEditMenuInteraction(delegate: nil)
        tv.addInteraction(menu)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        if tv.selectedRange.length == 0 { DispatchQueue.main.async { [weak self] in self?.endSelecting() } }
    }

    func textViewDidEndEditing(_ tv: UITextView) { endSelecting() }

    private func endSelecting() {
        guard let tv = selecting, tv.selectedRange.length == 0 || !tv.isFirstResponder else { return }
        selecting = nil
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        setNeedsDisplay()
    }

    override func willMove(toWindow w: UIWindow?) {
        super.willMove(toWindow: w)
        if w == nil, let tv = selecting { selecting = nil; tv.removeFromSuperview() }
    }
}
