import LinkPresentation
import UIKit

/// Site icons for links in messages. Fetched from the site itself (its /favicon.ico, then the icon
/// LinkPresentation finds in the page), never from a third-party favicon service, and cached on disk.
@MainActor
enum Favicons {
    static let loaded = Notification.Name("reason.favicon.loaded")

    private static var memory: [String: UIImage] = [:]
    private static var failed: Set<String> = []
    private static var inflight: Set<String> = []
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("favicons")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// "www.github.com" → "github.com"
    static func host(of url: URL) -> String? {
        guard let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The icon if we have it; otherwise starts a fetch and returns nil (a `loaded` note follows).
    static func icon(for host: String) -> UIImage? {
        if let hit = memory[host] { return hit }
        let file = dir.appendingPathComponent(host + ".png")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data, scale: 3) {
            memory[host] = img
            return img
        }
        fetch(host)
        return nil
    }

    private static func fetch(_ host: String) {
        guard !failed.contains(host), !inflight.contains(host), let base = URL(string: "https://\(host)") else { return }
        inflight.insert(host)
        Task {
            var img: UIImage?
            // 1. The conventional /favicon.ico (ImageIO reads .ico).
            if let (data, res) = try? await URLSession.shared.data(from: base.appendingPathComponent("favicon.ico")),
               (res as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: data), i.size.width >= 8 {
                img = i
            }
            // 2. Whatever icon the page declares.
            if img == nil { img = await linkPresentationIcon(base) }
            inflight.remove(host)
            guard let img, let png = normalized(img) else { failed.insert(host); return }
            try? png.pngData()?.write(to: dir.appendingPathComponent(host + ".png"))
            memory[host] = png
            NotificationCenter.default.post(name: loaded, object: host)
        }
    }

    private static func linkPresentationIcon(_ url: URL) async -> UIImage? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let meta = try? await provider.startFetchingMetadata(for: url), let ip = meta.iconProvider else { return nil }
        return await withCheckedContinuation { cont in
            ip.loadObject(ofClass: UIImage.self) { obj, _ in cont.resume(returning: obj as? UIImage) }
        }
    }

    /// 48 px square, so every icon draws the same size inline.
    private static func normalized(_ img: UIImage) -> UIImage? {
        let side: CGFloat = 16
        let f = UIGraphicsImageRendererFormat()
        f.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    // MARK: Inline decoration

    /// Puts each link's site icon just before it. GitHub gets its real mark in the text colour.
    /// Missing icons show a small globe of the same size, so nothing reflows when they arrive.
    static func decorate(_ s: NSAttributedString, font: UIFont, tint: UIColor) -> NSAttributedString {
        var links: [(NSRange, URL)] = []
        s.enumerateAttribute(.attachmentLinkKey, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let url = v as? URL { links.append((r, url)) }
        }
        guard !links.isEmpty else { return s }
        let out = NSMutableAttributedString(attributedString: s)
        let side = (font.pointSize * 0.92).rounded()
        // Merge adjacent runs of one link (bold parts split it), then insert from the end.
        var merged: [(NSRange, URL)] = []
        for (r, u) in links {
            if let last = merged.last, last.1 == u, NSMaxRange(last.0) == r.location {
                merged[merged.count - 1].0 = NSRange(location: last.0.location, length: last.0.length + r.length)
            } else { merged.append((r, u)) }
        }
        for (r, url) in merged.reversed() {
            guard let host = host(of: url), url.scheme?.hasPrefix("http") == true else { continue }
            if (s.string as NSString).substring(with: r).hasPrefix("🖼") { continue }
            let image: UIImage
            if host == "github.com" || host.hasSuffix(".github.com") {
                image = BrandIcon.github.image(size: side).withTintColor(tint, renderingMode: .alwaysOriginal)
            } else if let fav = icon(for: host) {
                image = rounded(fav, side: side)
            } else {
                image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .medium))?
                    .withTintColor(tint.withAlphaComponent(0.55), renderingMode: .alwaysOriginal) ?? UIImage()
            }
            let a = NSTextAttachment()
            a.image = image
            a.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
            let piece = NSMutableAttributedString(attachment: a)
            piece.append(NSAttributedString(string: "\u{2009}"))
            let attrs = out.attributes(at: r.location, effectiveRange: nil).filter { $0.key == .font || $0.key == .paragraphStyle }
            piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
            out.insert(piece, at: r.location)
        }
        return out
    }

    private static var roundedCache: [String: UIImage] = [:]
    private static func rounded(_ img: UIImage, side: CGFloat) -> UIImage {
        let key = "\(ObjectIdentifier(img).hashValue)@\(side)"
        if let hit = roundedCache[key] { return hit }
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let r = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(roundedRect: r, cornerRadius: side * 0.22).addClip()
            img.draw(in: r)
        }.withRenderingMode(.alwaysOriginal)
        roundedCache[key] = out
        return out
    }
}

extension UILabel {
    /// The link (`attachmentLinkKey`) under a point in this label, laid out exactly as the label draws it.
    func link(at point: CGPoint) -> URL? {
        guard let text = attributedText, text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyph = layout.glyphIndex(for: point, in: container)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let char = layout.characterIndexForGlyph(at: glyph)
        guard char < text.length else { return nil }
        // The icon in front of a link belongs to it too.
        for i in [char, min(char + 1, text.length - 1), min(char + 2, text.length - 1)] {
            if let url = text.attribute(.attachmentLinkKey, at: i, effectiveRange: nil) as? URL { return url }
            if i == char, text.attribute(.attachment, at: i, effectiveRange: nil) == nil { break }
        }
        return nil
    }
}

extension UIImage {
    func resized(to side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side * 0.22).addClip()
            draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.withRenderingMode(.alwaysOriginal)
    }
}
