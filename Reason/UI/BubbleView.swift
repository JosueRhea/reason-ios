import UIKit

/// Clean, tail-less bubble like Reason desktop. Corners facing a neighbour from the same
/// sender tighten so a run of messages reads as one block.
final class BubbleView: UIView {
    static let radius: CGFloat = 20
    static let joinedRadius: CGFloat = 6

    enum Side { case left, right }

    var side: Side = .left { didSet { if side != oldValue { setNeedsLayout() } } }
    var joinTop = false { didSet { if joinTop != oldValue { setNeedsLayout() } } }
    var joinBottom = false { didSet { if joinBottom != oldValue { setNeedsLayout() } } }
    var fillColor: UIColor = Theme.theirsBubble { didSet { updateColor() } }
    var strokeColor: UIColor? { didSet { updateColor() } }

    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(shape, at: 0)
        shape.lineWidth = 1 / UIScreen.main.scale
        updateColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: BubbleView, _: UITraitCollection) in v.updateColor() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.fillColor = fillColor.resolvedColor(with: traitCollection).cgColor
        shape.strokeColor = strokeColor?.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path().cgPath
        CATransaction.commit()
    }

    func path() -> UIBezierPath { Self.path(in: bounds, side: side, joinTop: joinTop, joinBottom: joinBottom) }

    static func path(in r: CGRect, side: Side, joinTop: Bool, joinBottom: Bool) -> UIBezierPath {
        let big = min(radius, r.height / 2, r.width / 2)
        let small = min(joinedRadius, big)
        // Corners on the sender's side tighten when joined.
        let leftSide = side == .left
        let tl = leftSide && joinTop ? small : big
        let bl = leftSide && joinBottom ? small : big
        let tr = !leftSide && joinTop ? small : big
        let br = !leftSide && joinBottom ? small : big
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(withCenter: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(withCenter: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(withCenter: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(withCenter: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        p.close()
        return p
    }
}
