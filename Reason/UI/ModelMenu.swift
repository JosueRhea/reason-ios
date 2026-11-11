import UIKit

/// The desktop app's model picker as native cascading menus:
/// Search · Reason › · ChatGPT › account › models · Claude › account › models · Settings.
@MainActor
enum ModelMenu {
    static func modelMenu(app: AppState, choice: ModelChoice, onSearch: @escaping () -> Void) -> UIMenu {
        var top: [UIMenuElement] = []

        top.append(UIAction(title: "Search models", image: UIImage(systemName: "magnifyingglass")) { _ in onSearch() })

        // Reason's own gateway models, split by how they're billed.
        let gateway = app.models.filter(\.isReasonGateway)
        var reasonChildren: [UIMenuElement] = [
            UIAction(title: "Reason default", subtitle: "The Reason picks for each turn",
                     image: BrandIcon.reason.image(size: 18), state: choice.model == nil ? .on : .off) { _ in
                choice.set(model: nil, source: nil, app: app)
            },
        ]
        var sections: [String: [ModelsResponse.Model]] = [:]
        var order: [String] = []
        for m in gateway {
            let k = m.detail ?? "Included with Reason"
            if sections[k] == nil { order.append(k) }
            sections[k, default: []].append(m)
        }
        for k in order {
            reasonChildren.append(UIMenu(title: k, options: .displayInline, children: sections[k]!.map { action(for: $0, source: nil, app: app, choice: choice) }))
        }
        top.append(UIMenu(title: "Reason", image: BrandIcon.reason.image(size: 18), children: reasonChildren))

        // Connected subscriptions: provider › account › models.
        for g in app.groups where g.selectable != false {
            let accounts = g.accounts ?? []
            let groupModels = (g.models ?? []).filter { $0.hidden != true && $0.available != false }
            let accountMenus: [UIMenuElement] = accounts.map { a in
                let ids = Set(a.modelIds ?? groupModels.map(\.id))
                let ms = groupModels.filter { ids.contains($0.id) }
                let selectedHere = choice.source == a.sourceId && ms.contains { $0.id == choice.model }
                return UIMenu(title: app.accountName(a, in: g),
                              subtitle: a.accountEmail,
                              image: UIImage(systemName: selectedHere ? "checkmark.circle.fill" : "person.crop.circle"),
                              children: ms.map { action(for: $0, source: a.sourceId, app: app, choice: choice) })
            }
            let selectedInGroup = accounts.contains { $0.sourceId == choice.source }
            top.append(UIMenu(title: g.label ?? g.providerId,
                              subtitle: selectedInGroup ? choice.currentModel(app)?.displayName : g.detail,
                              image: BrandIcon.forProvider(g.providerId).image(size: 18),
                              children: accountMenus.isEmpty ? groupModels.map { action(for: $0, source: nil, app: app, choice: choice) } : accountMenus))
        }

        let settings = UIAction(title: "Settings", image: UIImage(systemName: "arrow.up.right")) { _ in
            if let u = URL(string: "https://reasonmachines.com/customize?tab=models") { UIApplication.shared.open(u) }
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: top), UIMenu(options: .displayInline, children: [settings])])
    }

    private static func action(for m: ModelsResponse.Model, source: String?, app: AppState, choice: ModelChoice) -> UIAction {
        var bits: [String] = []
        if let cw = m.contextWindow { bits.append(cw >= 1_000_000 ? "\(cw / 1_000_000)M" : "\(cw / 1000)K") }
        if m.imageInput == true { bits.append("Images") }
        let on = choice.model == m.id && (source == nil || choice.source == source)
        return UIAction(title: m.displayName, subtitle: bits.isEmpty ? nil : bits.joined(separator: " · "),
                        image: BrandIcon.forModel(m.id).image(size: 18), state: on ? .on : .off) { _ in
            UISelectionFeedbackGenerator().selectionChanged()
            choice.set(model: m.id, source: source, app: app)
        }
    }

    static func effortMenu(app: AppState, choice: ModelChoice) -> UIMenu {
        let efforts = choice.currentModel(app)?.reasoningEfforts ?? ["low", "medium", "high", "xhigh", "max"]
        let options: [String?] = [nil] + efforts
        let actions: [UIMenuElement] = options.map { e in
            UIAction(title: EffortSlider.title(e), subtitle: e == nil ? "Let the model decide" : nil,
                     image: UIImage(systemName: icon(for: e)), state: choice.effort == e ? .on : .off) { _ in
                UISelectionFeedbackGenerator().selectionChanged()
                choice.setEffort(e)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: "Reasoning", options: .displayInline, children: actions)]
        if choice.currentModel(app)?.supportsFast == true {
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Fast mode", subtitle: "Priority tier on your ChatGPT plan", image: UIImage(systemName: "bolt.fill"),
                         state: choice.fast ? .on : .off) { _ in
                    choice.toggleFast()
                },
            ]))
        }
        return UIMenu(children: children)
    }

    private static func icon(for e: String?) -> String {
        switch e {
        case nil: return "sparkles"
        case "minimal", "low": return "gauge.with.dots.needle.0percent"
        case "medium": return "gauge.with.dots.needle.33percent"
        case "high": return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
