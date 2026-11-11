#if DEBUG
import UIKit

/// Every chat element in every state, with fake data, for checking alignment. DEBUG builds only;
/// opened when the `debugGallery` default is set. Sends nothing.
final class DebugGalleryViewController: UIViewController {
    private enum Item {
        case stamp(String)
        case message(MessageModel)
        case live([LiveStep], String?, String?)
        case request(InputRequest)
        case pills
        case composer(InputBar.Mode, running: Bool)
    }
    private var items: [Item] = []
    private var cv: UICollectionView!
    private var streamTimer: Timer?

    /// Simulated stream: the server's growing snapshots, one chunk every 0.6 s.
    private static let streamed = "I've asked the setup Session to bring the pull request up to date with main. It will fix any conflicts, push the update and check that **CI** still passes. It still won't merge without your approval, and I'll tell you as soon as the checks come back green. Run `pnpm test` locally if you want to double-check."

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard UserDefaults.standard.bool(forKey: "debugStream") else { return }
        items.insert(.live([], nil, "Working 3s"), at: 0)
        cv.reloadData()
        var len = 0
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                len = min(Self.streamed.count, len + Int.random(in: 25...70))
                self.items[0] = .live([], String(Self.streamed.prefix(len)), "Working \(3 + len / 40)s")
                self.cv.reconfigureItems(at: [IndexPath(item: 0, section: 0)])
                if len >= Self.streamed.count { t.invalidate() }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        title = "UI gallery"
        items = Self.fixtures()
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60))
        let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 40, trailing: 0)
        cv = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        cv.backgroundColor = .clear
        cv.dataSource = self
        for (cls, id): (AnyClass, String) in [(MessageCell.self, MessageCell.reuse), (StampCell.self, StampCell.reuse), (LiveCell.self, LiveCell.reuse),
                        (ReportCell.self, ReportCell.reuse), (NoticeCell.self, NoticeCell.reuse), (AgentNoteCell.self, AgentNoteCell.reuse),
                        (ChildEventCell.self, ChildEventCell.reuse), (RequestCell.self, RequestCell.reuse)] as [(AnyClass, String)] {
            cv.register(cls as AnyClass?, forCellWithReuseIdentifier: id)
        }
        cv.register(HostCell.self, forCellWithReuseIdentifier: "host")
        view.addSubview(cv)
        cv.pin(to: view)
    }

    private static func fixtures() -> [Item] {
        func m(_ id: String, _ text: String, mine: Bool = false, top: Bool = false, bottom: Bool = false, footer: String? = "10:03 PM",
               style: MessageModel.Style = .bubble, chips: [LinkChip] = [], files: [AttachmentRef] = [], images: [Markdown.ImageRef] = [],
               expanded: Bool = false, header: String? = nil) -> Item {
            var x = MessageModel(id: id, text: text, mine: mine, joinTop: top, joinBottom: bottom, failed: false, header: header,
                                 footer: footer, images: images, topGap: top ? 3 : 14)
            x.style = style; x.chips = chips; x.files = files; x.expanded = expanded
            return .message(x)
        }
        let pr = LinkChip(kind: .pullRequest, title: "acme/app #101", url: URL(string: "https://github.com/acme/app/pull/101")!)
        let sess = LinkChip(kind: .session("x"), title: "Set up acme/app", url: URL(string: "https://reasonmachines.com/agents/x")!)
        let prev = LinkChip(kind: .preview, title: "Preview :3000", url: URL(string: "https://reasonmachines.com/agents/x/preview?port=3000")!)
        let img = Markdown.ImageRef(url: URL(string: "https://api.reasonmachines.com/media/pr-screenshots/4be5ff17-fd71-449b-ab63-1d8d4863291a/360ff8afd29c836e8dd991409c2f05c5/mac-win.jpg")!,
                                    alt: "dbui on Rune", aspect: 1600.0 / 2360.0)
        let fileTheirs = AttachmentRef(LocalFile(id: "f1", url: URL(fileURLWithPath: "/tmp/report.pdf"), name: "quarterly-report.pdf", contentType: "application/pdf", size: 482_133))
        let fileMine = AttachmentRef(LocalFile(id: "f2", url: URL(fileURLWithPath: "/tmp/main.swift"), name: "ChatViewController.swift", contentType: "text/plain", size: 61_220))
        return [
            .pills,
            .stamp("Today 10:03 PM"),
            m("a", "Can u catch up with main", mine: true),
            m("lnk1", "https://github.com/acme/dbui\n\nthe thing we want to rebuild in rune", mine: true),
            m("md1", """
## Deploy plan
Three steps, all **reversible**. See [the runbook](https://github.com/acme/app/pull/102).

1. Build the bundle
   - Node build with `esbuild`
   - Browser build, minified
2. Publish with `pnpm --filter brain-runner publish:agent --prod`
3. Wake every VM

> Nothing is deployed yet. The check on **PR #102** failed while installing packages.

- [x] Merge main
- [ ] Deploy Convex

| Step | Time | Status |
|------|-----:|:------:|
| Build | 42s | ✅ |
| Publish | 1m 10s | ⏳ |

---

```bash
set -uo pipefail
# fetch the release
info=$(curl -fsS --max-time 30 "$CONVEX_SITE_URL/brain/vm/release")
if [ "$new" != "$(cat current/VERSION)" ]; then
  tar -xzf "$dir.tgz" -C "$dir"
fi
```

```ts
export async function publishRelease(ctx: Ctx, version: string): Promise<void> {
  const rows = await ctx.db.query("agentReleases").take(5) // keep five
  return null
}
```
"""),
            m("lnk2", "Docs are at https://docs.reasonmachines.com/docs/guide and the deploy is on [Vercel](https://vercel.com/dashboard). Apple's notes: https://developer.apple.com/documentation/uikit and the PR is [#102](https://github.com/acme/app/pull/102)."),
            .message({ var x = MessageModel(id: "c", text: "The user asks: \"Can u catch up with main\". Update PR #101's branch with the latest main (merge or rebase, whichever fits the repo), resolve any conflicts, push, and make sure CI passes.\nDon't merge.", mine: false, joinTop: false, joinBottom: false, failed: false, header: nil, footer: nil, images: [], topGap: 14)
                x.style = .childEvent(verb: "Messaged", title: "Set up acme/app", sessionId: "x", status: "running"); return x }()),
            .message({ var x = MessageModel(id: "c2", text: "Port the desk app to Rune.", mine: false, joinTop: false, joinBottom: false, failed: false, header: nil, footer: nil, images: [], topGap: 14)
                x.style = .childEvent(verb: "Started", title: "Port reason-desk from gpui to Rune", sessionId: "y", status: "finished"); return x }()),
            m("b", "I've asked the setup Session to bring the pull request up to date with main. It will fix any conflicts, push the update and check that **CI** still passes.", bottom: true, footer: nil),
            m("b2", "It still won't merge without your approval. Run `pnpm test` locally if you want to double-check.", top: true, footer: "Claude Opus 5.5 · High · 10:03 PM"),
            .live([LiveStep(id: "1", icon: "brain", title: "Thinking", detail: nil, done: true, failed: false),
                   LiveStep(id: "2", icon: "terminal", title: "Ran", detail: "git fetch origin main && git rebase origin/main", done: true, failed: false),
                   LiveStep(id: "3", icon: "arrow.triangle.branch", title: "Messaged session", detail: "Set up acme/app", done: false, failed: false)],
                  nil, "Working 42s · 2 steps"),
            .live([], "Rebasing onto main now; one conflict in `convex/jobs.ts`…", "Working 1m 3s · 4 steps"),
            .live([], nil, nil),
            m("r1", "PR #101 has already been merged into `main`, so there's nothing to catch up. Its changes are part of main now.\n\nI didn't change or push anything.", style: .report(title: "Set up acme/app", state: .finished, sessionId: "x"), chips: [pr], images: [img]),
            m("r2", "(no reply produced)\n\nIt was stopped before it finished.", style: .report(title: "Port reason-desk from gpui to Rune", state: .stopped, sessionId: "y")),
            m("n", "GitHub is now connected to this Workspace.", footer: nil, style: .notice),
            m("an", "Hello from the desk app", mine: true, footer: nil, style: .agentNote(from: "reason-desk · you@example.com")),
            m("an2", "Hello from the desk app, expanded", mine: true, footer: nil, style: .agentNote(from: "reason-desk · you@example.com"), expanded: true),
            m("img", "Here's the window running on your Mac.", images: [img]),
            m("files", "", footer: "10:04 PM", files: [fileTheirs]),
            m("filesMine", "Attached ChatViewController.swift", mine: true, footer: nil, files: [fileMine]),
            m("chips", "Opened the preview and the PR for you.", chips: [prev, pr, sess]),
            .request(InputRequest(id: "q", type: "question", status: "pending", label: "Which branch should I deploy?",
                                  reason: "Two release branches exist and they differ.", createdAt: nil,
                                  question: .init(waitForAnswer: true, questions: [.init(header: "Branch", question: "Deploy which branch to staging?", multiSelect: false,
                                                                                          options: [.init(label: "main", description: "Latest merged work"), .init(label: "release/2.4", description: nil)])]),
                                  secretRequest: nil, networkHosts: nil, permissionRules: nil, actions: ["answer"], appUrl: nil)),
            .request(InputRequest(id: "s", type: "secret", status: "pending", label: "Recall API key", reason: "Needed to start the meeting bot.", createdAt: nil,
                                  question: nil, secretRequest: .init(name: "RECALL_API_KEY", label: nil, placeholder: "rk_live_…", valuePrefix: "rk_", replace: false),
                                  networkHosts: nil, permissionRules: nil, actions: ["secret", "cancel"], appUrl: nil)),
            .request(InputRequest(id: "h", type: "network_hosts", status: "pending", label: "Allow access to api.recall.ai", reason: nil, createdAt: nil,
                                  question: nil, secretRequest: nil, networkHosts: .init(hosts: ["api.recall.ai", "us-west-2.recall.ai"]), permissionRules: nil,
                                  actions: ["approve", "deny"], appUrl: nil)),
            .composer(.typing, running: false),
            .composer(.typing, running: true),
            .composer(.holding, running: false),
            .composer(.locked, running: false),
        ]
    }
}

extension DebugGalleryViewController: UICollectionViewDataSource {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        switch items[ip.item] {
        case .stamp(let t):
            let c = cv.dequeueReusableCell(withReuseIdentifier: StampCell.reuse, for: ip) as! StampCell
            c.label.text = t
            return c
        case .message(let m):
            switch m.style {
            case .bubble:
                let c = cv.dequeueReusableCell(withReuseIdentifier: MessageCell.reuse, for: ip) as! MessageCell; c.configure(m); return c
            case .report:
                let c = cv.dequeueReusableCell(withReuseIdentifier: ReportCell.reuse, for: ip) as! ReportCell; c.configure(m); return c
            case .notice:
                let c = cv.dequeueReusableCell(withReuseIdentifier: NoticeCell.reuse, for: ip) as! NoticeCell; c.configure(m); return c
            case .agentNote:
                let c = cv.dequeueReusableCell(withReuseIdentifier: AgentNoteCell.reuse, for: ip) as! AgentNoteCell; c.configure(m); return c
            case .childEvent:
                let c = cv.dequeueReusableCell(withReuseIdentifier: ChildEventCell.reuse, for: ip) as! ChildEventCell
                c.configure(m, appearance: Appearance(color: "blue", eyes: "pills", shape: nil)); return c
            }
        case .live(let steps, let text, let summary):
            let c = cv.dequeueReusableCell(withReuseIdentifier: LiveCell.reuse, for: ip) as! LiveCell
            c.configure(steps: steps, text: text, summaryText: summary); return c
        case .request(let r):
            let c = cv.dequeueReusableCell(withReuseIdentifier: RequestCell.reuse, for: ip) as! RequestCell; c.configure(r); return c
        case .pills:
            let c = cv.dequeueReusableCell(withReuseIdentifier: "host", for: ip) as! HostCell
            let row = UIStackView()
            row.spacing = 8
            row.distribution = .equalCentering
            for (state, status) in [(AvatarView.State.idle, nil), (.working, "Running git status"), (.sleeping, nil)] as [(AvatarView.State, String?)] {
                let p = TitlePill()
                p.configure(name: "Atlas", appearance: Appearance(color: "blue", eyes: "pills", shape: nil))
                p.setStatus(status)
                p.avatar.state = state
                row.addArrangedSubview(p)
            }
            c.host(row)
            return c
        case .composer(let mode, let running):
            let c = cv.dequeueReusableCell(withReuseIdentifier: "host", for: ip) as! HostCell
            let bar = InputBar()
            bar.setModel(nil, effort: "high", fast: false)
            bar.isRunning = running
            if mode == .holding || mode == .locked { bar.debugShowRecording(locked: mode == .locked) }
            c.host(bar)
            return c
        }
    }
}

/// Hosts an arbitrary view in the gallery.
private final class HostCell: UICollectionViewCell {
    func host(_ v: UIView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.addSubview(v)
        v.pin(to: contentView, insets: UIEdgeInsets(top: 12, left: 12, bottom: 4, right: 12))
    }
}
#endif
