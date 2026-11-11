import UIKit

// MARK: - Provider badge

/// Small rounded mark identifying who makes a model.
final class ProviderBadge: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        label.textAlignment = .center
        label.textColor = .white
        addSubview(label)
        label.pin(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width * 0.3
        label.font = .systemFont(ofSize: bounds.width * 0.5, weight: .bold)
    }

    func configure(modelId: String?) {
        let (mark, color) = Self.style(for: modelId)
        label.text = mark
        backgroundColor = color
    }

    static func style(for id: String?) -> (String, UIColor) {
        let s = (id ?? "").lowercased()
        if id == nil { return ("R", UIColor(white: 0.1, alpha: 1)) }
        if s.contains("claude") || s.contains("anthropic") { return ("A", UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)) }
        if s.contains("gpt") || s.contains("openai") { return ("◎", UIColor(red: 0.06, green: 0.64, blue: 0.5, alpha: 1)) }
        if s.contains("gemini") || s.contains("google") { return ("G", UIColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)) }
        if s.contains("deepseek") { return ("D", UIColor(red: 0.30, green: 0.42, blue: 0.99, alpha: 1)) }
        if s.contains("glm") || s.contains("zhipu") { return ("Z", UIColor(red: 0.20, green: 0.22, blue: 0.30, alpha: 1)) }
        if s.contains("qwen") { return ("Q", UIColor(red: 0.42, green: 0.30, blue: 0.95, alpha: 1)) }
        if s.contains("kimi") || s.contains("moonshot") { return ("K", .black) }
        return (String(s.split(separator: "/").last?.first ?? "•").uppercased(), .systemGray)
    }
}

// MARK: - Effort slider

/// Segmented control with a springy sliding pill; drag across it or tap a level.
final class EffortSlider: UIControl {
    private(set) var options: [String?] = []
    private(set) var selectedIndex = 0
    private let pill = UIView()
    private var labels: [UILabel] = []
    private let feedback = UISelectionFeedbackGenerator()

    var selectedValue: String? { options.indices.contains(selectedIndex) ? options[selectedIndex] : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerCurve = .continuous
        pill.backgroundColor = .systemBackground
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.12
        pill.layer.shadowRadius = 4
        pill.layer.shadowOffset = CGSize(width: 0, height: 1)
        pill.isUserInteractionEnabled = false
        addSubview(pill)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 36) }

    static func title(_ e: String?) -> String {
        switch e {
        case nil: return "Auto"
        case "xhigh": return "X-High"
        case let e?: return e.capitalized
        }
    }

    func setOptions(_ opts: [String?], selected: String?, animated: Bool) {
        let changed = opts != options
        options = opts
        selectedIndex = opts.firstIndex(where: { $0 == selected }) ?? 0
        if changed {
            labels.forEach { $0.removeFromSuperview() }
            labels = opts.map { o in
                let l = UILabel()
                l.text = Self.title(o)
                l.textAlignment = .center
                l.adjustsFontSizeToFitWidth = true
                l.minimumScaleFactor = 0.7
                addSubview(l)
                return l
            }
            if animated {
                // New set of levels: labels ripple in.
                for (i, l) in labels.enumerated() {
                    l.alpha = 0
                    l.transform = CGAffineTransform(translationX: 0, y: 6)
                    UIView.animate(withDuration: 0.4, delay: 0.025 * Double(i), usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                        l.alpha = 1; l.transform = .identity
                    }
                }
            }
        }
        setNeedsLayout()
        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                self.layoutIfNeeded()
            }
        }
        styleLabels()
    }

    private var segmentWidth: CGFloat { options.isEmpty ? 0 : (bounds.width - 6) / CGFloat(options.count) }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let w = segmentWidth
        for (i, l) in labels.enumerated() {
            l.frame = CGRect(x: 3 + CGFloat(i) * w + 2, y: 0, width: w - 4, height: bounds.height)
        }
        pill.frame = CGRect(x: 3 + CGFloat(selectedIndex) * w, y: 3, width: w, height: bounds.height - 6)
        pill.layer.cornerRadius = pill.bounds.height / 2
    }

    private func styleLabels() {
        for (i, l) in labels.enumerated() {
            l.font = .systemFont(ofSize: 13, weight: i == selectedIndex ? .semibold : .regular)
            l.textColor = i == selectedIndex ? .label : .secondaryLabel
        }
    }

    private func select(_ i: Int) {
        let i = max(0, min(options.count - 1, i))
        guard i != selectedIndex else { return }
        selectedIndex = i
        feedback.selectionChanged()
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.setNeedsLayout(); self.layoutIfNeeded()
        }
        UIView.transition(with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.styleLabels() }
        sendActions(for: .valueChanged)
    }

    private func index(at p: CGPoint) -> Int { Int((p.x - 3) / max(1, segmentWidth)) }

    @objc private func tap(_ g: UITapGestureRecognizer) { select(index(at: g.location(in: self))) }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            feedback.prepare()
            UIView.animate(withDuration: 0.2) { self.pill.transform = CGAffineTransform(scaleX: 0.94, y: 0.94) }
            select(index(at: g.location(in: self)))
        case .changed:
            select(index(at: g.location(in: self)))
        default:
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) { self.pill.transform = .identity }
        }
    }
}

// MARK: - Picker

final class ModelPickerViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating {
    private struct Row: Hashable { let id: String?; let source: String? }   // nil id = Reason default

    var onChange: (() -> Void)?
    var focusSearch = false

    private let app = AppState.shared!
    private let choice: ModelChoice

    init(choice: ModelChoice) {
        self.choice = choice
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, Row>!
    private let effort = EffortSlider()
    private let fastRow = UIStackView()
    private let fastSwitch = UISwitch()
    private var query = ""
    private static let allEfforts = ["low", "medium", "high", "xhigh", "max"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Model"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search models"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        // Header: effort + fast mode
        let effortTitle = UILabel()
        effortTitle.text = "REASONING EFFORT"
        effortTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        effortTitle.textColor = .secondaryLabel
        effort.addTarget(self, action: #selector(effortChanged), for: .valueChanged)

        let bolt = UIImageView(image: UIImage(systemName: "bolt.fill"))
        bolt.tintColor = .systemYellow
        let fastLabel = UILabel()
        fastLabel.text = "Fast mode"
        fastLabel.font = .systemFont(ofSize: 15)
        let fastHint = UILabel()
        fastHint.text = "Priority tier on your ChatGPT subscription"
        fastHint.font = .systemFont(ofSize: 12)
        fastHint.textColor = .secondaryLabel
        let fastTexts = UIStackView(arrangedSubviews: [fastLabel, fastHint])
        fastTexts.axis = .vertical
        fastSwitch.isOn = choice.fast
        fastSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.fastSwitch.isOn != self.choice.fast { self.choice.toggleFast() }
            self.onChange?()
        }, for: .valueChanged)
        [bolt, fastTexts, fastSwitch].forEach(fastRow.addArrangedSubview)
        fastRow.spacing = 10
        fastRow.alignment = .center

        let header = UIStackView(arrangedSubviews: [effortTitle, effort, fastRow])
        header.axis = .vertical
        header.spacing = 8
        header.setCustomSpacing(14, after: effort)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        cfg.headerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: cfg))
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let cell = UICollectionView.CellRegistration<ModelCell, Row> { [weak self] c, _, row in
            guard let self else { return }
            let m = self.app.models.first { $0.id == row.id }
            c.configure(model: m, selected: self.isSelected(row))
        }
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] v, _, ip in
            var c = UIListContentConfiguration.header()
            c.text = self?.dataSource.sectionIdentifier(for: ip.section)
            v.contentConfiguration = c
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, row in
            cv.dequeueConfiguredReusableCell(using: cell, for: ip, item: row)
        }
        dataSource.supplementaryViewProvider = { cv, _, ip in cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: ip) }

        NotificationCenter.default.addObserver(forName: .modelsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(animated: true) }
        }
        apply(animated: false)
        syncHeader(animated: false)
        Task { await app.loadModels() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if focusSearch { navigationItem.searchController?.searchBar.becomeFirstResponder() }
        if let ip = dataSource.snapshot().itemIdentifiers.first(where: isSelected).flatMap(dataSource.indexPath(for:)) {
            collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: true)
        }
    }

    private func isSelected(_ r: Row) -> Bool {
        choice.model == r.id && (r.source == nil || choice.source == r.source)
    }

    private func apply(animated: Bool) {
        var s = NSDiffableDataSourceSnapshot<String, Row>()
        let q = query.lowercased()
        func matches(_ m: ModelsResponse.Model) -> Bool { q.isEmpty || m.displayName.lowercased().contains(q) || m.id.lowercased().contains(q) }
        if q.isEmpty || "reason default automatic".contains(q) {
            s.appendSections(["Reason"])
            s.appendItems([Row(id: nil, source: nil)], toSection: "Reason")
        }
        for m in app.models where m.isReasonGateway && matches(m) {
            let section = "Reason · " + (m.detail ?? "Included")
            if !s.sectionIdentifiers.contains(section) { s.appendSections([section]) }
            s.appendItems([Row(id: m.id, source: nil)], toSection: section)
        }
        for g in app.groups where g.selectable != false {
            let gm = (g.models ?? []).filter { $0.hidden != true && $0.available != false }
            for a in g.accounts ?? [] {
                let ids = Set(a.modelIds ?? gm.map(\.id))
                let rows = gm.filter { ids.contains($0.id) && matches($0) }.map { Row(id: $0.id, source: a.sourceId) }
                guard !rows.isEmpty else { continue }
                let section = "\(g.label ?? g.providerId) · \(app.accountName(a, in: g))"
                s.appendSections([section])
                s.appendItems(rows, toSection: section)
            }
        }
        dataSource.apply(s, animatingDifferences: animated)
    }

    private func syncHeader(animated: Bool) {
        let m = choice.currentModel(app)
        let opts: [String?] = [nil] + (m?.reasoningEfforts ?? Self.allEfforts)
        effort.setOptions(opts, selected: choice.effort, animated: animated)
        let showFast = m?.supportsFast == true
        guard fastRow.isHidden == showFast else { return }
        let change = { self.fastRow.isHidden = !showFast; self.fastRow.alpha = showFast ? 1 : 0 }
        animated ? UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, animations: {
            change(); self.view.layoutIfNeeded()
        }) : change()
    }

    @objc private func effortChanged() {
        choice.setEffort(effort.selectedValue)
        onChange?()
    }

    func updateSearchResults(for sc: UISearchController) {
        query = sc.searchBar.text ?? ""
        apply(animated: true)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        guard let row = dataSource.itemIdentifier(for: ip), !isSelected(row) else { return }
        choice.set(model: row.id, source: row.source, app: app)
        UISelectionFeedbackGenerator().selectionChanged()
        for r in dataSource.snapshot().itemIdentifiers {
            if let ip = dataSource.indexPath(for: r), let c = cv.cellForItem(at: ip) as? ModelCell {
                c.configure(model: app.models.first { $0.id == r.id }, selected: isSelected(r), animated: r == row)
            }
        }
        syncHeader(animated: true)
        onChange?()
    }
}

// MARK: - Model cell

final class ModelCell: UICollectionViewListCell {
    private let badge = UIImageView()
    private let name = UILabel()
    private let meta = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 16, weight: .medium)
        meta.font = .systemFont(ofSize: 12)
        meta.textColor = .secondaryLabel
        check.tintColor = .label
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)
        let texts = UIStackView(arrangedSubviews: [name, meta])
        texts.axis = .vertical
        texts.spacing = 1
        let row = UIStackView(arrangedSubviews: [badge, texts, check])
        row.spacing = 12
        row.alignment = .center
        contentView.addSubview(row)
        row.pin(to: contentView, insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
        badge.translatesAutoresizingMaskIntoConstraints = false
        check.translatesAutoresizingMaskIntoConstraints = false
        check.contentMode = .scaleAspectFit
        check.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            check.widthAnchor.constraint(equalToConstant: 24),
            check.heightAnchor.constraint(equalToConstant: 24),
        ])
        separatorLayoutGuide.leadingAnchor.constraint(equalTo: texts.leadingAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(model m: ModelsResponse.Model?, selected: Bool, animated: Bool = false) {
        badge.image = BrandIcon.forModel(m?.id).image(size: 22)
        badge.tintColor = .label
        badge.contentMode = .center
        name.text = m?.displayName ?? "Reason default"
        var bits: [String] = []
        if m == nil { bits.append("Uses the Reason's own model") }
        if let cw = m?.contextWindow { bits.append(cw >= 1_000_000 ? "\(cw / 1_000_000)M context" : "\(cw / 1000)K context") }
        if m?.imageInput == true { bits.append("Images") }
        if m?.supportsFast == true { bits.append("Fast available") }
        meta.text = bits.joined(separator: " · ")
        meta.isHidden = bits.isEmpty

        let show = { self.check.alpha = selected ? 1 : 0; self.check.transform = selected ? .identity : CGAffineTransform(scaleX: 0.4, y: 0.4) }
        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 4, animations: show)
            if selected {
                check.addSymbolEffect(.bounce)
                badge.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) { self.badge.transform = .identity }
            }
        } else {
            show()
        }
    }
}
