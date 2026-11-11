import UIKit

/// The Reason bot: a soft octagon (or circle) with one of six eye styles, alive in three states.
///  - idle: blinks now and then
///  - working: an orbiting arc, eyes scanning, a gentle bob
///  - sleeping: eyes closed, slow breathing, little "z"s drifting up
final class AvatarView: UIView {
    enum State { case idle, working, sleeping }

    private let body = CAShapeLayer()
    private let face = CALayer()          // eyes + brows, moved as one
    private let leftEye = CALayer()
    private let rightEye = CALayer()
    private let leftBrow = CALayer()
    private let rightBrow = CALayer()
    private let ring = CAShapeLayer()     // working orbit
    private let zzz = CALayer()           // sleeping particles
    private var appearance: Appearance?
    private var blinkTimer: Timer?
    private var zTimer: Timer?

    var animatesIdle = true { didSet { scheduleBlink() } }
    var state: State = .idle { didSet { if state != oldValue { applyState(animated: true) } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ring.fillColor = UIColor.clear.cgColor
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = 0.28
        ring.opacity = 0
        layer.addSublayer(ring)
        layer.addSublayer(body)
        for l in [leftEye, rightEye, leftBrow, rightBrow] { face.addSublayer(l) }
        layer.addSublayer(face)
        layer.addSublayer(zzz)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: AvatarView, _: UITraitCollection) in v.configure(v.appearance) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Look

    private var eyeStyle: String { appearance?.eyes ?? "pills" }

    func configure(_ appearance: Appearance?) {
        self.appearance = appearance
        let color = Theme.reasonColor(appearance?.color).resolvedColor(with: traitCollection)
        body.fillColor = color.cgColor
        let lightBody = color.luminance > 0.6
        let eye = (lightBody ? UIColor(white: 0.1, alpha: 1) : .white).cgColor
        for l in [leftEye, rightEye, leftBrow, rightBrow] { l.backgroundColor = eye }
        ring.strokeColor = (traitCollection.userInterfaceStyle == .dark ? UIColor.white : color).withAlphaComponent(0.55).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = bounds
        let w = r.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = r
        body.path = (appearance?.shape == "circle" ? UIBezierPath(ovalIn: r) : Self.octagon(in: r)).cgPath
        face.frame = r
        zzz.frame = r

        let inset = -max(2, w * 0.09)
        ring.frame = r
        ring.lineWidth = max(1.5, w * 0.05)
        ring.path = UIBezierPath(ovalIn: r.insetBy(dx: inset, dy: inset)).cgPath

        // Eye geometry per style.
        var ew = w * 0.095, eh = w * 0.26, gap = w * 0.09, dy = -w * 0.02
        switch eyeStyle {
        case "dots": ew = w * 0.13; eh = ew; gap = w * 0.12
        case "small": ew = w * 0.085; eh = ew; gap = w * 0.08
        case "wide": ew = w * 0.17; eh = w * 0.1; gap = w * 0.1
        case "sleepy": ew = w * 0.15; eh = w * 0.055; gap = w * 0.1; dy = w * 0.02
        case "brows": ew = w * 0.095; eh = w * 0.2; gap = w * 0.1; dy = w * 0.02
        default: break
        }
        ew = max(1.5, ew); eh = max(1.5, eh)
        for e in [leftEye, rightEye] {
            e.bounds = CGRect(x: 0, y: 0, width: ew, height: eh)
            e.cornerRadius = min(ew, eh) / 2
        }
        leftEye.position = CGPoint(x: r.midX - gap / 2 - ew / 2, y: r.midY + dy)
        rightEye.position = CGPoint(x: r.midX + gap / 2 + ew / 2, y: r.midY + dy)

        let showBrows = eyeStyle == "brows"
        for (b, e) in [(leftBrow, leftEye), (rightBrow, rightEye)] {
            b.isHidden = !showBrows
            b.bounds = CGRect(x: 0, y: 0, width: ew * 1.8, height: max(1, w * 0.04))
            b.cornerRadius = b.bounds.height / 2
            b.position = CGPoint(x: e.position.x, y: e.position.y - eh / 2 - w * 0.07)
        }
        leftBrow.setAffineTransform(CGAffineTransform(rotationAngle: 0.18))
        rightBrow.setAffineTransform(CGAffineTransform(rotationAngle: -0.18))
        CATransaction.commit()
        if state != .idle { applyState(animated: false) }
    }

    static func octagon(in r: CGRect) -> UIBezierPath {
        let c = r.width * 0.29, rad = r.width * 0.12
        let pts = [
            CGPoint(x: r.minX + c, y: r.minY), CGPoint(x: r.maxX - c, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY + c), CGPoint(x: r.maxX, y: r.maxY - c),
            CGPoint(x: r.maxX - c, y: r.maxY), CGPoint(x: r.minX + c, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY - c), CGPoint(x: r.minX, y: r.minY + c),
        ]
        let p = UIBezierPath()
        for i in 0..<pts.count {
            let prev = pts[(i + pts.count - 1) % pts.count], cur = pts[i], next = pts[(i + 1) % pts.count]
            let a = toward(cur, prev, rad), b = toward(cur, next, rad)
            if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
            p.addQuadCurve(to: b, controlPoint: cur)
        }
        p.close()
        return p
    }

    private static func toward(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, len = max(0.001, hypot(dx, dy))
        return CGPoint(x: from.x + dx / len * d, y: from.y + dy / len * d)
    }

    // MARK: States

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            blinkTimer?.invalidate(); zTimer?.invalidate()
        } else {
            scheduleBlink()
            applyState(animated: false)
        }
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private func applyState(animated: Bool) {
        guard window != nil else { return }
        // Clear the previous state's loops.
        for k in ["orbit", "orbitFade"] { ring.removeAnimation(forKey: k) }
        for k in ["scan", "bob", "breathe"] { face.removeAnimation(forKey: k); layer.removeAnimation(forKey: k) }
        zTimer?.invalidate(); zTimer = nil

        let closed: CGFloat = state == .sleeping ? 0.14 : 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.45 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for e in [leftEye, rightEye] { e.transform = CATransform3DMakeScale(1, closed, 1) }
        face.transform = state == .sleeping ? CATransform3DMakeTranslation(0, bounds.height * 0.04, 0) : CATransform3DIdentity
        ring.opacity = state == .working && bounds.width >= 36 ? 1 : 0
        CATransaction.commit()

        guard !reduceMotion else { return }
        switch state {
        case .working:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = Double.pi * 2
            spin.duration = 1.1; spin.repeatCount = .infinity
            ring.add(spin, forKey: "orbit")
            let grow = CAKeyframeAnimation(keyPath: "strokeEnd")
            grow.values = [0.12, 0.38, 0.12]; grow.duration = 1.6; grow.repeatCount = .infinity
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ring.add(grow, forKey: "orbitFade")

            if bounds.width < 36 {
                // Too small for an orbit: breathe instead.
                let pulse = CABasicAnimation(keyPath: "transform.scale")
                pulse.fromValue = 1; pulse.toValue = 0.9
                pulse.duration = 0.6; pulse.autoreverses = true; pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(pulse, forKey: "breathe")
            }
            let scan = CAKeyframeAnimation(keyPath: "transform.translation.x")
            let d = bounds.width * 0.08
            scan.values = [0, d, d, -d, -d, 0]
            scan.keyTimes = [0, 0.15, 0.4, 0.55, 0.85, 1]
            scan.duration = 2.4; scan.repeatCount = .infinity
            scan.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            face.add(scan, forKey: "scan")

            guard bounds.width >= 36 else { return }
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0; bob.toValue = -bounds.height * 0.035
            bob.duration = 0.55; bob.autoreverses = true; bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bob, forKey: "bob")
        case .sleeping:
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1; breathe.toValue = 0.955
            breathe.duration = 2.2; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(breathe, forKey: "breathe")
            if bounds.width >= 26 {
                emitZ()
                zTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.emitZ() }
                }
            }
        case .idle:
            break
        }
    }

    /// A "z" rises from the top-right corner, growing and fading.
    private func emitZ() {
        let w = bounds.width
        let t = CATextLayer()
        t.string = "z"
        t.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
        t.fontSize = max(7, w * 0.26)
        t.foregroundColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        t.contentsScale = UIScreen.main.scale
        t.alignmentMode = .center
        t.frame = CGRect(x: w * 0.78, y: w * 0.02, width: t.fontSize, height: t.fontSize * 1.2)
        t.opacity = 0
        zzz.addSublayer(t)

        let dur = 2.4
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = t.position
        move.toValue = CGPoint(x: t.position.x + w * 0.22, y: t.position.y - w * 0.45)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5; scale.toValue = 1.25
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.7, 0]; fade.keyTimes = [0, 0.2, 0.7, 1]
        let g = CAAnimationGroup()
        g.animations = [move, scale, fade]
        g.duration = dur
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.isRemovedOnCompletion = true
        t.add(g, forKey: "rise")
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { t.removeFromSuperlayer() }
    }

    // MARK: Idle life

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        guard window != nil, animatesIdle, !reduceMotion else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.5...6), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state != .sleeping { self.blink(double: self.state == .working && Bool.random()) }
                self.scheduleBlink()
            }
        }
    }

    func blink(double: Bool = false) {
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = double ? [1, 0.12, 1, 0.12, 1] : [1, 0.12, 1]
        a.keyTimes = double ? [0, 0.2, 0.45, 0.7, 1] : [0, 0.45, 1]
        a.duration = double ? 0.42 : 0.22
        a.isAdditive = false
        leftEye.add(a, forKey: "blink")
        rightEye.add(a, forKey: "blink")
    }

    /// Kept for callers that only know "busy or not".
    func setThinking(_ on: Bool) { state = on ? .working : (state == .working ? .idle : state) }

    /// Springy hop, e.g. when a reply lands.
    func bounce() {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.82
        a.toValue = 1
        a.damping = 9
        a.stiffness = 260
        a.mass = 0.8
        a.duration = a.settlingDuration
        layer.add(a, forKey: "bounce")
    }
}

extension UIColor {
    /// Relative luminance, to pick eye colour against the body.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

extension AvatarView {
    /// A still of the avatar on a soft tinted disc, for places that take an image (notification sender photos).
    static func snapshot(_ appearance: Appearance?, size: CGFloat = 180, dark: Bool = false) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let color = Theme.reasonColor(appearance?.color).resolvedColor(with: traits)
        let v = AvatarView(frame: CGRect(x: 0, y: 0, width: size * 0.62, height: size * 0.62))
        v.animatesIdle = false
        v.overrideUserInterfaceStyle = dark ? .dark : .light
        v.configure(appearance)
        v.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let bg = dark ? UIColor(white: 0.13, alpha: 1) : .white
            bg.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            color.withAlphaComponent(dark ? 0.28 : 0.16).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.cgContext.translateBy(x: (size - v.bounds.width) / 2, y: (size - v.bounds.height) / 2 + size * 0.01)
            v.layer.render(in: ctx.cgContext)
        }
    }
}
