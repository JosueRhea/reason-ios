import UIKit

struct BrandPath {
    let viewBox: (CGFloat, CGFloat, CGFloat, CGFloat)
    let evenOdd: Bool
    let d: String

    /// The parsed path in viewBox coordinates.
    var bezier: UIBezierPath { SVGPath.parse(d) }
}

/// Provider marks (from T3 Code) rendered as vector images.
enum BrandIcon: String {
    case openai, anthropic, claude, gemini, openrouter, reason, deepseek, glm, github, other

    static func forModel(_ id: String?) -> BrandIcon {
        guard let s = id?.lowercased(), s != "reason", !s.hasPrefix("reason/") else { return .reason }
        if s.contains("claude") || s.contains("anthropic") { return .anthropic }
        if s.contains("gpt") || s.contains("openai") || s.contains("codex") { return .openai }
        if s.contains("gemini") || s.contains("google") { return .gemini }
        if s.contains("openrouter") { return .openrouter }
        if s.contains("deepseek") { return .deepseek }
        if s.contains("glm") { return .glm }
        return .other
    }

    static func forProvider(_ providerId: String?) -> BrandIcon {
        switch providerId {
        case "openai-codex", "openai": return .openai
        case "anthropic": return .anthropic
        case "openrouter": return .openrouter
        case "google", "gemini": return .gemini
        default: return .reason
        }
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// Template image (tinted by the view) except for marks that carry their own colour.
    func image(size: CGFloat = 18) -> UIImage {
        let key = "\(rawValue)@\(size)" as NSString
        if let hit = Self.cache.object(forKey: key) { return hit }
        let img = render(size: size)
        Self.cache.setObject(img, forKey: key)
        return img
    }

    private func render(size: CGFloat) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        switch self {
        case .gemini:
            let src = UIImage(named: "brand-gemini") ?? UIImage()
            return UIGraphicsImageRenderer(size: canvas).image { _ in
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: size * 0.22).addClip()
                src.draw(in: CGRect(origin: .zero, size: canvas))
            }.withRenderingMode(.alwaysOriginal)
        case .reason:
            return UIGraphicsImageRenderer(size: canvas).image { _ in
                let r = CGRect(origin: .zero, size: canvas)
                UIColor.black.setFill()
                AvatarView.octagon(in: r).fill()
                UIColor.white.setFill()
                let w = size * 0.1, h = size * 0.28, gap = size * 0.09
                UIBezierPath(roundedRect: CGRect(x: r.midX - gap / 2 - w, y: r.midY - h / 2, width: w, height: h), cornerRadius: w / 2).fill()
                UIBezierPath(roundedRect: CGRect(x: r.midX + gap / 2, y: r.midY - h / 2, width: w, height: h), cornerRadius: w / 2).fill()
            }.withRenderingMode(.alwaysOriginal)
        case .deepseek, .glm, .other:
            let letter = self == .deepseek ? "D" : (self == .glm ? "Z" : "•")
            return UIGraphicsImageRenderer(size: canvas).image { _ in
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.72, weight: .bold), .foregroundColor: UIColor.black]
                let s = letter as NSString
                let ts = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2), withAttributes: attrs)
            }.withRenderingMode(.alwaysTemplate)
        case .openai, .anthropic, .claude, .openrouter, .github:
            let bp: BrandPath = self == .openai ? BrandPaths.openai : self == .anthropic ? BrandPaths.anthropic
                : self == .claude ? BrandPaths.claude : self == .github ? BrandPaths.github : BrandPaths.openrouter
            let path = bp.bezier
            let (vx, vy, vw, vh) = bp.viewBox
            let scale = size / max(vw, vh)
            path.apply(CGAffineTransform(translationX: -vx, y: -vy))
            path.apply(CGAffineTransform(scaleX: scale, y: scale))
            path.apply(CGAffineTransform(translationX: (size - vw * scale) / 2, y: (size - vh * scale) / 2))
            path.usesEvenOddFillRule = bp.evenOdd
            let tinted = self != .claude
            return UIGraphicsImageRenderer(size: canvas).image { _ in
                (tinted ? UIColor.black : UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)).setFill()
                path.fill()
            }.withRenderingMode(tinted ? .alwaysTemplate : .alwaysOriginal)
        }
    }
}

/// Minimal SVG path-data parser: M L H V C S Q T Z, absolute and relative (no arcs needed here).
enum SVGPath {
    static func parse(_ d: String) -> UIBezierPath {
        let path = UIBezierPath()
        var scanner = Tokenizer(d)
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint? = nil
        var lastQuad: CGPoint? = nil

        while let next = scanner.peekCommand() ?? (scanner.hasNumber ? cmd : nil) {
            if scanner.peekCommand() != nil { cmd = scanner.takeCommand() }
            let rel = cmd.isLowercase
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            _ = next
            switch cmd.uppercased().first! {
            case "M":
                guard let p = pt() else { return path }
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"           // subsequent pairs are implicit linetos
                lastCtrl = nil; lastQuad = nil
            case "L":
                guard let p = pt() else { return path }
                path.addLine(to: p); cur = p; lastCtrl = nil; lastQuad = nil
            case "H":
                guard let x = scanner.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil; lastQuad = nil
            case "V":
                guard let y = scanner.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil; lastQuad = nil
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastCtrl = c2; lastQuad = nil
            case "S":
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastCtrl = c2; lastQuad = nil
            case "Q":
                guard let c = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, controlPoint: c); cur = p; lastQuad = c; lastCtrl = nil
            case "T":
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = pt() else { return path }
                path.addQuadCurve(to: p, controlPoint: c); cur = p; lastQuad = c; lastCtrl = nil
            case "Z":
                path.close(); cur = start; lastCtrl = nil; lastQuad = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Tokenizer {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }

        mutating func peekCommand() -> Character? {
            skip()
            guard i < chars.count, chars[i].isLetter, chars[i] != "e", chars[i] != "E" else { return nil }
            return chars[i]
        }
        mutating func takeCommand() -> Character { let c = chars[i]; i += 1; return c }

        var hasNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," { j += 1 }
            return j < chars.count && (chars[j].isNumber || chars[j] == "-" || chars[j] == "." || chars[j] == "+")
        }

        /// Numbers may run together: "1.5.5" is 1.5 then .5, "2-3" is 2 then -3.
        mutating func number() -> CGFloat? {
            skip()
            var s = ""
            var seenDot = false, seenExp = false
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c) }
                else if c == "." && !seenDot && !seenExp { seenDot = true; s.append(c) }
                else if (c == "e" || c == "E") && !seenExp { seenExp = true; s.append(c)
                    if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" { i += 1; s.append(chars[i]) } }
                else { break }
                i += 1
            }
            return Double(s).map { CGFloat($0) }
        }
    }
}
