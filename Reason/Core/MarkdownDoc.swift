import UIKit

/// Block-level markdown: headings, lists, quotes, code fences, tables and rules.
/// Text-like blocks that follow each other merge into one attributed string, so a reply is a
/// handful of views (text, code, table) rather than one per paragraph.
enum MDBlock: Hashable {
    case text(NSAttributedString)
    case quote(NSAttributedString)
    case code(lang: String?, code: String)
    case table(header: [NSAttributedString], rows: [[NSAttributedString]], align: [NSTextAlignment])
    case rule
}

enum MarkdownDoc {
    private static let cache = NSCache<NSString, NSArray>()

    // MARK: Parse

    static func parse(_ raw: String, color: UIColor, font: UIFont = Theme.bodyFont, linkColor: UIColor) -> [MDBlock] {
        let key = "\(raw.hashValue)|\(color.hashValue)|\(linkColor.hashValue)|\(font.pointSize)" as NSString
        if let hit = cache.object(forKey: key) as? [MDBlock] { return hit }
        var parser = Parser(text: Markdown.unflatten(raw), color: color, font: font, linkColor: linkColor)
        let blocks = parser.run()
        cache.setObject(blocks as NSArray, forKey: key)
        return blocks
    }

    /// Everything as one attributed string (code and tables as monospace text), for single-label places.
    static func flattened(_ blocks: [MDBlock], color: UIColor, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let mono = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.84, weight: .regular)
        for b in blocks {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            switch b {
            case .text(let s), .quote(let s): out.append(s)
            case .code(_, let code):
                let p = NSMutableParagraphStyle(); p.paragraphSpacing = 8
                out.append(NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: color.withAlphaComponent(0.85), .paragraphStyle: p]))
            case .table(let h, let rows, _):
                let lines = ([h] + rows).map { $0.map(\.string).joined(separator: "  ·  ") }.joined(separator: "\n")
                out.append(NSAttributedString(string: lines, attributes: [.font: font, .foregroundColor: color]))
            case .rule:
                out.append(NSAttributedString(string: "———", attributes: [.font: font, .foregroundColor: color.withAlphaComponent(0.3)]))
            }
        }
        // The last paragraph's spacing would only pad the bottom.
        if out.length > 0 {
            out.enumerateAttribute(.paragraphStyle, in: NSRange(location: out.length - 1, length: 1)) { v, r, _ in
                guard let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                p.paragraphSpacing = 0
                out.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }
        return out
    }

    private struct Parser {
        let lines: [String]
        let color: UIColor, font: UIFont, linkColor: UIColor
        var i = 0
        var blocks: [MDBlock] = []
        var text = NSMutableAttributedString()

        init(text: String, color: UIColor, font: UIFont, linkColor: UIColor) {
            lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            self.color = color; self.font = font; self.linkColor = linkColor
        }

        // Paragraph styles
        var bodyStyle: NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle(); p.lineSpacing = 2.5; p.paragraphSpacing = 10; return p
        }

        mutating func run() -> [MDBlock] {
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { markBlankLine(); i += 1; continue }
                if let fence = fenceStart(t) { code(fence); continue }
                if isRule(t) { flush(); blocks.append(.rule); i += 1; continue }
                if let h = heading(t) { heading(h.level, h.text); i += 1; continue }
                if isTableStart() { table(); continue }
                if t.hasPrefix(">") { quote(); continue }
                if let item = listItem(line) { list(item); i += 1; continue }
                paragraph(t)
                i += 1
            }
            flush()
            return blocks
        }

        mutating func flush() {
            guard text.length > 0 else { return }
            trimTrailingSpacing(text)
            blocks.append(.text(text))
            text = NSMutableAttributedString()
        }

        mutating func append(_ s: NSAttributedString) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: s.attributes(at: 0, effectiveRange: nil))) }
            text.append(s)
        }

        /// A blank line ends a list or paragraph group: give the previous paragraph full spacing.
        mutating func markBlankLine() {
            guard text.length > 0 else { return }
            let r = NSRange(location: text.length - 1, length: 1)
            if let p = (text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                p.paragraphSpacing = max(p.paragraphSpacing, 10)
                text.addAttribute(.paragraphStyle, value: p, range: lineRange(text, at: r.location))
            }
        }

        // MARK: Paragraphs and headings

        mutating func paragraph(_ t: String) {
            // Lines inside one paragraph sit close; a blank line (or the next block) opens it up.
            let p = bodyStyle
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            if !next.isEmpty, listItem(lines[i + 1]) == nil, heading(next) == nil, fenceStart(next) == nil { p.paragraphSpacing = 3 }
            let s = Markdown.inline(hardBreak(t), font: font, color: color, linkColor: linkColor, para: p)
            append(s)
        }

        func hardBreak(_ t: String) -> String {
            t.hasSuffix("\\") ? String(t.dropLast()) : t
        }

        func heading(_ t: String) -> (level: Int, text: String)? {
            guard t.hasPrefix("#") else { return nil }
            let hashes = t.prefix { $0 == "#" }.count
            guard hashes <= 6, t.count > hashes, t[t.index(t.startIndex, offsetBy: hashes)] == " " else { return nil }
            var body = String(t.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
            body = body.replacingOccurrences(of: #"\s#+$"#, with: "", options: .regularExpression)
            return (hashes, body)
        }

        mutating func heading(_ level: Int, _ body: String) {
            let size: CGFloat, weight: UIFont.Weight
            switch level {
            case 1: size = font.pointSize + 6; weight = .bold
            case 2: size = font.pointSize + 3.5; weight = .bold
            case 3: size = font.pointSize + 1.5; weight = .semibold
            default: size = font.pointSize; weight = .semibold
            }
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = text.length > 0 || !blocks.isEmpty ? (level <= 2 ? 12 : 8) : 0
            p.paragraphSpacing = level <= 2 ? 6 : 4
            p.lineSpacing = 1
            let hf = UIFont.systemFont(ofSize: size, weight: weight)
            // Inline bold inside a heading would double up; strip the stars.
            let s = Markdown.inline(body.replacingOccurrences(of: "**", with: ""), font: hf, color: color, linkColor: linkColor, para: p)
            append(s)
        }

        // MARK: Lists

        struct Item { let indent: Int; let marker: String; let ordered: Bool; let body: String; let task: Bool? }

        func listItem(_ line: String) -> Item? {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let indent = lead.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let rest = line.dropFirst(lead.count)
            if let m = rest.first, "-*+•".contains(m), rest.dropFirst().first == " " {
                var body = String(rest.dropFirst(2))
                var task: Bool?
                if body.hasPrefix("[ ] ") { task = false; body.removeFirst(4) }
                else if body.lowercased().hasPrefix("[x] ") { task = true; body.removeFirst(4) }
                return Item(indent: indent, marker: String(m), ordered: false, body: body, task: task)
            }
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let after = rest.dropFirst(digits.count)
                if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                    return Item(indent: indent, marker: digits + ".", ordered: true, body: String(after.dropFirst(2)), task: nil)
                }
            }
            return nil
        }

        mutating func list(_ first: Item) {
            // Indentation → nesting level, measured against the items seen so far.
            var item = first
            var levels: [Int] = []
            while true {
                while let last = levels.last, item.indent < last { levels.removeLast() }
                if levels.last.map({ item.indent > $0 + 1 }) ?? true { levels.append(item.indent) }
                let level = min(levels.count - 1, 3)
                // Continuation lines (indented text that isn't a new item) join the item.
                var body = item.body
                while i + 1 < lines.count {
                    let nxt = lines[i + 1]
                    let nt = nxt.trimmingCharacters(in: .whitespaces)
                    guard !nt.isEmpty, listItem(nxt) == nil, nxt.hasPrefix("  ") || nxt.hasPrefix("\t"),
                          fenceStart(nt) == nil else { break }
                    body += "\n" + nt
                    i += 1
                }
                appendItem(item, body: body, level: level)
                // Next line another item (blank lines between items allowed)?
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count, let n = listItem(lines[j]) else { break }
                if j > i + 1 { markBlankLine() }
                i = j
                item = n
            }
            setLastSpacing(10)
        }

        mutating func appendItem(_ item: Item, body: String, level: Int) {
            let step: CGFloat = 20
            let markerWidth: CGFloat = item.ordered ? max(22, measure(item.marker) + 7) : (item.task != nil ? 26 : 16)
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2.5
            p.paragraphSpacing = 5
            p.firstLineHeadIndent = CGFloat(level) * step
            p.headIndent = CGFloat(level) * step + markerWidth
            p.tabStops = [NSTextTab(textAlignment: .left, location: p.headIndent)]
            p.defaultTabInterval = p.headIndent

            let markerText: String
            if let done = item.task { markerText = done ? "☑" : "☐" }
            else if item.ordered { markerText = item.marker }
            else { markerText = ["•", "◦", "▪", "◦"][level] }
            let mf: UIFont = item.ordered ? UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
                : .systemFont(ofSize: item.task != nil ? font.pointSize : font.pointSize * (level == 2 ? 0.7 : 1.05), weight: .bold)
            let s = NSMutableAttributedString(string: markerText + "\t", attributes: [
                .font: mf, .foregroundColor: color.withAlphaComponent(item.ordered ? 0.6 : 0.45), .paragraphStyle: p,
            ])
            let bodyAttr = Markdown.inline(body.replacingOccurrences(of: "\n", with: "\u{2028}"), font: font, color: color, linkColor: linkColor, para: p)
            if item.task == true { bodyAttr.addAttributes([.foregroundColor: color.withAlphaComponent(0.55),
                                                            .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                                                           range: NSRange(location: 0, length: bodyAttr.length)) }
            if let done = item.task {
                // A real checkbox glyph instead of the tiny ☐/☑ characters.
                let side = font.pointSize * 1.05
                let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.9, weight: .medium)
                let img = UIImage(systemName: done ? "checkmark.circle.fill" : "circle", withConfiguration: cfg)?
                    .withTintColor(done ? UIColor.systemGreen : color.withAlphaComponent(0.35), renderingMode: .alwaysOriginal)
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
                let box = NSMutableAttributedString(attachment: att)
                box.append(NSAttributedString(string: "\t"))
                box.addAttributes([.font: font, .paragraphStyle: p], range: NSRange(location: 0, length: box.length))
                s.setAttributedString(box)
            }
            s.append(bodyAttr)
            append(s)
        }

        func measure(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)]).width
        }

        mutating func setLastSpacing(_ v: CGFloat) {
            guard text.length > 0 else { return }
            let r = lineRange(text, at: text.length - 1)
            if let p = (text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                p.paragraphSpacing = v
                text.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }

        // MARK: Quotes

        mutating func quote() {
            var body: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                body.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            flush()
            // A nested parse keeps lists and emphasis inside the quote.
            var sub = Parser(text: body.joined(separator: "\n"), color: color.withAlphaComponent(0.72), font: font, linkColor: linkColor)
            let inner = sub.run()
            let joined = NSMutableAttributedString()
            for b in inner {
                if case .text(let s) = b {
                    if joined.length > 0 { joined.append(NSAttributedString(string: "\n")) }
                    joined.append(s)
                }
            }
            if joined.length > 0 { trimTrailingSpacing(joined); blocks.append(.quote(joined)) }
        }

        // MARK: Code

        func fenceStart(_ t: String) -> String? {
            for f in ["```", "~~~"] where t.hasPrefix(f) { return f }
            return nil
        }

        mutating func code(_ fence: String) {
            let open = lines[i].trimmingCharacters(in: .whitespaces)
            let lang = open.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            let indent = lines[i].prefix { $0 == " " }.count
            var body: [String] = []
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(fence) { i += 1; break }
                var l = lines[i]
                // Fences inside list items are indented; drop that indent from the code.
                if indent > 0 { l = String(l.dropFirst(min(indent, l.prefix { $0 == " " }.count))) }
                body.append(l)
                i += 1
            }
            flush()
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            blocks.append(.code(lang: lang?.isEmpty == false ? lang : nil, code: body.joined(separator: "\n")))
        }

        // MARK: Rules and tables

        func isRule(_ t: String) -> Bool {
            let c = t.replacingOccurrences(of: " ", with: "")
            guard c.count >= 3, let f = c.first, "-*_".contains(f) else { return false }
            return c.allSatisfy { $0 == f }
        }

        func cells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            // Split on pipes that aren't escaped or inside `code`.
            var out: [String] = [], cur = "", inCode = false, prev: Character = " "
            for ch in t {
                if ch == "`" { inCode.toggle() }
                if ch == "|", !inCode, prev != "\\" { out.append(cur); cur = "" } else { cur.append(ch) }
                prev = ch
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
        }

        func isSeparator(_ line: String) -> Bool {
            let cs = cells(line)
            return !cs.isEmpty && cs.allSatisfy { c in
                let s = c.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && s.allSatisfy { "-:".contains($0) } && s.contains("-")
            }
        }

        func isTableStart() -> Bool {
            guard i + 1 < lines.count, lines[i].contains("|") else { return false }
            return isSeparator(lines[i + 1]) && cells(lines[i]).count >= 2
        }

        mutating func table() {
            let header = cells(lines[i])
            let align: [NSTextAlignment] = cells(lines[i + 1]).map { s in
                let l = s.hasPrefix(":"), r = s.hasSuffix(":")
                return l && r ? .center : (r ? .right : .left)
            }
            i += 2
            var rows: [[String]] = []
            while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(cells(lines[i])); i += 1
            }
            flush()
            let n = header.count
            let cellFont = UIFont.systemFont(ofSize: font.pointSize - 1.5)
            let headFont = UIFont.systemFont(ofSize: font.pointSize - 1.5, weight: .semibold)
            func render(_ s: String, _ f: UIFont) -> NSAttributedString {
                Markdown.inline(s, font: f, color: color, linkColor: linkColor)
            }
            blocks.append(.table(
                header: header.map { render($0, headFont) },
                rows: rows.map { r in (0..<n).map { render($0 < r.count ? r[$0] : "", cellFont) } },
                align: (0..<n).map { $0 < align.count ? align[$0] : .left }))
        }
    }

    static func lineRange(_ s: NSAttributedString, at loc: Int) -> NSRange {
        (s.string as NSString).paragraphRange(for: NSRange(location: loc, length: 0))
    }

    static func trimTrailingSpacing(_ s: NSMutableAttributedString) {
        guard s.length > 0 else { return }
        let r = lineRange(s, at: s.length - 1)
        if let p = (s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            p.paragraphSpacing = 0
            s.addAttribute(.paragraphStyle, value: p, range: r)
        }
    }
}

private func lineRange(_ s: NSAttributedString, at loc: Int) -> NSRange { MarkdownDoc.lineRange(s, at: loc) }
private func trimTrailingSpacing(_ s: NSMutableAttributedString) { MarkdownDoc.trimTrailingSpacing(s) }

// MARK: - Syntax highlighting

/// A small regex highlighter: comments, strings, numbers, keywords, shell variables and calls.
/// Not a parser, but it reads like an editor for the languages agents usually show.
enum SyntaxHighlight {
    struct Palette {
        let text, comment, string, keyword, number, variable, function, type: UIColor
    }

    static let palette = Palette(
        text: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.13, alpha: 1) },
        comment: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.5, alpha: 1) : UIColor(white: 0.52, alpha: 1) },
        string: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.99, green: 0.55, blue: 0.47, alpha: 1) : UIColor(red: 0.72, green: 0.16, blue: 0.10, alpha: 1) },
        keyword: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.99, green: 0.47, blue: 0.70, alpha: 1) : UIColor(red: 0.61, green: 0.14, blue: 0.58, alpha: 1) },
        number: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.84, green: 0.79, blue: 0.53, alpha: 1) : UIColor(red: 0.11, green: 0.36, blue: 0.80, alpha: 1) },
        variable: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.47, green: 0.76, blue: 0.99, alpha: 1) : UIColor(red: 0.04, green: 0.39, blue: 0.70, alpha: 1) },
        function: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.40, green: 0.85, blue: 0.80, alpha: 1) : UIColor(red: 0.20, green: 0.42, blue: 0.48, alpha: 1) },
        type: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.85, blue: 0.62, alpha: 1) : UIColor(red: 0.11, green: 0.44, blue: 0.25, alpha: 1) })

    private static let keywords: Set<String> = [
        // shell
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return",
        "export", "local", "set", "exec", "source", "echo", "cd", "exit", "readonly", "unset", "shift", "trap", "eval",
        // C-family / Swift / JS / TS / Go / Rust / Python
        "let", "var", "const", "func", "fn", "def", "class", "struct", "enum", "interface", "type", "protocol", "extension",
        "import", "from", "as", "export", "default", "public", "private", "fileprivate", "internal", "static", "final",
        "override", "async", "await", "try", "catch", "throw", "throws", "new", "this", "self", "super", "nil", "null",
        "undefined", "true", "false", "True", "False", "None", "and", "or", "not", "is", "lambda", "with", "yield", "pass",
        "break", "continue", "switch", "guard", "defer", "where", "match", "impl", "pub", "mut", "use", "mod", "crate",
        "package", "go", "chan", "select", "extends", "implements", "typeof", "instanceof", "void", "delete", "of", "elif",
        "except", "finally", "raise", "global", "assert", "loop", "dyn", "ref", "move", "unsafe", "some", "any", "inout",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON", "AND",
        "OR", "NOT", "NULL", "ORDER", "BY", "GROUP", "LIMIT", "AS", "LEFT", "INNER", "PRIMARY", "KEY",
    ]

    private static let cache = NSCache<NSString, NSAttributedString>()

    static func highlight(_ code: String, lang: String?, font: UIFont) -> NSAttributedString {
        let key = "\(code.hashValue)|\(lang ?? "")|\(font.pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let p = palette
        let out = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: p.text])
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        let l = (lang ?? "").lowercased()
        let plain = ["text", "txt", "plain", "output", "log"].contains(l)
        guard !plain, code.utf16.count < 40_000 else { cache.setObject(out, forKey: key); return out }
        let hashComments = ["sh", "bash", "zsh", "shell", "console", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "", "dockerfile", "make", "makefile", "r", "perl", "conf", "ini"].contains(l)
        var taken = IndexSet()

        func paint(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = [], group: Int = 0, claim: Bool = true, italic: Bool = false) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: code, range: full) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                if taken.intersects(integersIn: r.location..<(r.location + r.length)) { continue }
                out.addAttribute(.foregroundColor, value: color, range: r)
                if italic, let d = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    out.addAttribute(.font, value: UIFont(descriptor: d, size: font.pointSize), range: r)
                }
                if claim { taken.insert(integersIn: r.location..<(r.location + r.length)) }
            }
        }

        // Order matters: comments and strings claim their ranges first.
        paint(#"/\*[\s\S]*?\*/"#, p.comment, italic: true)
        if l != "sh" && l != "bash" && l != "zsh" && l != "shell" { paint(#"(?<![:\w])//[^\n]*"#, p.comment, italic: true) }
        if hashComments { paint(#"(?:^|(?<=\s))#(?!!)[^\n]*"#, p.comment, options: [.anchorsMatchLines], italic: true) }
        if ["sql", "lua", "haskell", "hs"].contains(l) { paint(#"--[^\n]*"#, p.comment, italic: true) }
        paint(#""(?:[^"\\\n]|\\.)*""#, p.string)
        paint(#"'(?:[^'\\\n]|\\.)*'"#, p.string)
        paint(#"`(?:[^`\\]|\\.)*`"#, p.string)
        paint(#"\$\{[^}\n]*\}|\$\(|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]"#, p.variable)
        paint(#"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|\b0x[0-9a-fA-F]+\b"#, p.number)
        if let re = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#) {
            for m in re.matches(in: code, range: full) {
                let r = m.range
                if taken.intersects(integersIn: r.location..<(r.location + r.length)) { continue }
                let w = ns.substring(with: r)
                if keywords.contains(w) {
                    out.addAttribute(.foregroundColor, value: p.keyword, range: r)
                } else if let first = w.first, first.isUppercase, w.count > 1, w.contains(where: \.isLowercase) {
                    out.addAttribute(.foregroundColor, value: p.type, range: r)
                } else if NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r)) == 40 /* ( */ {
                    out.addAttribute(.foregroundColor, value: p.function, range: r)
                }
            }
        }
        // Shell: flags read a little quieter.
        if hashComments { paint(#"(?<=\s)--?[A-Za-z][\w-]*"#, p.function) }
        cache.setObject(out, forKey: key)
        return out
    }
}
