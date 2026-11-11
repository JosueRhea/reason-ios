import UIKit

/// Lightweight inline-markdown → NSAttributedString for bubbles.
/// Rendered once per message and cached, so scrolling never re-parses.
enum Markdown {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func render(_ text: String, color: UIColor, font: UIFont = Theme.bodyFont, linkColor: UIColor) -> NSAttributedString {
        let key = "\(text.hashValue)|\(color.hashValue)|\(font.pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // One attributed string for places that draw a single label: code blocks and tables fold into text.
        let out = MarkdownDoc.flattened(MarkdownDoc.parse(text, color: color, font: font, linkColor: linkColor), color: color, font: font)
        cache.setObject(out, forKey: key)
        return out
    }

    private static let inlineMarks = CharacterSet(charactersIn: "*_`[]~\\<&")

    /// Inline markdown (bold, italic, code, links, strikethrough) for one line or paragraph.
    static func inline(_ text: String, font: UIFont, color: UIColor, linkColor: UIColor,
                       para: NSParagraphStyle? = nil) -> NSMutableAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let para { base[.paragraphStyle] = para }
        // Most lines have no inline markup; Foundation's markdown parser is the slow part, so skip it.
        if text.rangeOfCharacter(from: inlineMarks) == nil, !text.contains("://"), !text.contains("www.") {
            return NSMutableAttributedString(string: text, attributes: base)
        }
        let out = NSMutableAttributedString()
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        let src = text.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)\s]+)\)"#, with: "[🖼 $1]($2)", options: .regularExpression)
        guard let parsed = try? AttributedString(markdown: src, options: opts) else {
            return NSMutableAttributedString(string: text, attributes: base)
        }
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.86, weight: .regular)
        for run in parsed.runs {
            var attrs = base
            let intent = run.inlinePresentationIntent ?? []
            var f = font
            if intent.contains(.code) {
                f = mono
                attrs[.backgroundColor] = color.withAlphaComponent(0.075)
                attrs[.foregroundColor] = color.withAlphaComponent(0.92)
            } else {
                if intent.contains(.stronglyEmphasized), !font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                    f = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                }
                if intent.contains(.emphasized), let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                    f = UIFont(descriptor: d, size: f.pointSize)
                }
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = f
            if let link = run.link {
                attrs[.foregroundColor] = linkColor
                attrs[.attachmentLinkKey] = link
                if linkColor == color { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }   // in our bubble
            }
            var piece = String(parsed[run.range].characters)
            if intent.contains(.code) { piece = "\u{202F}" + piece + "\u{202F}" }   // air inside the tint that never wraps alone
            // A bare URL (its text is the address itself) reads like the desktop: "github.com/acme/dbui".
            if let link = run.link, link.scheme?.hasPrefix("http") == true {
                let bare = piece.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if bare == link.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) { piece = prettyURL(link) }
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        linkifyBareURLs(out, linkColor: linkColor)
        return out
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain "https://github.com/acme/dbui" becomes a link that reads "github.com/acme/dbui".
    /// Code spans and existing markdown links are left alone.
    private static func linkifyBareURLs(_ out: NSMutableAttributedString, linkColor: UIColor) {
        guard let detector, out.string.contains("://") else { return }
        let matches = detector.matches(in: out.string, range: NSRange(location: 0, length: out.length))
        for m in matches.reversed() {
            guard let url = m.url, url.scheme?.hasPrefix("http") == true, m.range.length > 8 else { continue }
            var skip = false
            out.enumerateAttributes(in: m.range) { a, _, stop in
                if a[.attachmentLinkKey] != nil || a[.backgroundColor] != nil { skip = true; stop.pointee = true }
            }
            if skip { continue }
            var attrs = out.attributes(at: m.range.location, effectiveRange: nil)
            attrs[.foregroundColor] = linkColor
            attrs[.attachmentLinkKey] = url
            out.replaceCharacters(in: m.range, with: NSAttributedString(string: prettyURL(url), attributes: attrs))
        }
    }

    /// "https://www.github.com/a/b/" → "github.com/a/b", trimmed to a readable length.
    static func prettyURL(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        let s = host + path
        return s.count > 52 ? String(s.prefix(51)) + "…" : s
    }

    /// Some replies arrive with their structure flattened onto one line; put the breaks back.
    static func unflatten(_ text: String) -> String {
        var unflattened = text.replacingOccurrences(of: #"(?<=\S) - (?=\*\*)"#, with: "\n- ", options: .regularExpression)
        guard !text.contains("\n"), text.count > 280 else { return unflattened }
        for (pattern, template) in [
            (#" (#{1,4}) (?=\S)"#, "\n\n$1 "),                                     // "… ## 1. Build"
            (#"(?<=[.!?]) (\*\*[^*:\n]{2,48}\*\*) "#, "\n\n$1\n"),          // bold phrase after a sentence: a heading
            (#"(?<=[.:!?)\]]) (\d{1,2})\. (?=\*\*|\p{Lu}|")"#, "\n$1. "),        // "… 2. Meeting tools"
            (#"(?<=[.:!?)\]]|:\*\*) - (?=\S)"#, "\n- "),                   // "…: - list meetings", "**Label:** - When"
        ] {
            unflattened = unflattened.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Inside a list item, " - lowercase" starts the next item ("- list meetings - read notes").
        return unflattened.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("- ") else { return line }
            return line.replacingOccurrences(of: #" - (?=\p{Ll})"#, with: "\n- ", options: .regularExpression)
        }.joined(separator: "\n")
    }

    struct ImageRef: Hashable {
        let url: URL
        let alt: String
        let aspect: CGFloat      // height / width, from the "#w=…&h=…" hint when present
    }

    /// Pulls `![alt](url)` out of the text so images render as real thumbnails, not links.
    private static var imageMemo: [String: (String, [ImageRef])] = [:]
    private static let imageRE = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    static func extractImages(_ text: String) -> (String, [ImageRef]) {
        guard text.contains("![") else { return (text, []) }
        if let hit = imageMemo[text] { return hit }
        let r = scanImages(text)
        if imageMemo.count > 1000 { imageMemo.removeAll() }
        imageMemo[text] = r
        return r
    }

    private static func scanImages(_ text: String) -> (String, [ImageRef]) {
        let re = imageRE
        let ns = text as NSString
        var refs: [ImageRef] = []
        var seen = Set<URL>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let alt = ns.substring(with: m.range(at: 1))
            let raw = ns.substring(with: m.range(at: 2))
            guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true, !seen.contains(url) else { continue }
            seen.insert(url)
            var aspect: CGFloat = 0.625
            if let frag = url.fragment {
                let kv = Dictionary(frag.split(separator: "&").compactMap { p -> (String, Double)? in
                    let parts = p.split(separator: "=")
                    guard parts.count == 2, let v = Double(parts[1]) else { return nil }
                    return (String(parts[0]), v)
                }, uniquingKeysWith: { a, _ in a })
                if let w = kv["w"], let h = kv["h"], w > 0 { aspect = CGFloat(h / w) }
            }
            refs.append(ImageRef(url: url, alt: alt, aspect: min(max(aspect, 0.3), 1.6)))
        }
        // Content can arrive cut mid-image ("![alt](https://api.reasonma"): drop the dangling fragment.
        let dangling = text.replacingOccurrences(of: #"!\[[^\]]*(\]\([^)\s]*)?$"#, with: "", options: .regularExpression)
        guard !refs.isEmpty else { return (dangling == text ? text : dangling.trimmingCharacters(in: .whitespacesAndNewlines), []) }
        var stripped = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        stripped = stripped.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    /// Links found in a rendered string, for the context menu.
    static func links(in s: NSAttributedString) -> [(String, URL)] {
        var found: [(String, URL)] = []
        s.enumerateAttribute(.attachmentLinkKey, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let u = v as? URL { found.append(((s.string as NSString).substring(with: r), u)) }
        }
        return found
    }

    /// Plain text for previews: strip the common markdown punctuation.
    static func plain(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        for token in ["**", "__", "`", "#"] { s = s.replacingOccurrences(of: token, with: "") }
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.replacingOccurrences(of: "\n", with: " ")
    }
}

extension NSAttributedString.Key {
    /// Custom key: UILabel ignores `.link` styling rules, so keep URLs here.
    static let attachmentLinkKey = NSAttributedString.Key("reason.link")
}
