import UIKit

/// Full-screen zoomable image with a hero transition from its thumbnail and drag-to-dismiss.
final class ImageViewerController: UIViewController, UIScrollViewDelegate, UIViewControllerTransitioningDelegate {
    private let ref: Markdown.ImageRef
    private weak var source: UIImageView?
    private let scroll = UIScrollView()
    let imageView = UIImageView()
    private let caption = UILabel()
    private let close = UIButton(type: .system)
    private let dim = UIView()

    init(ref: Markdown.ImageRef, source: UIImageView) {
        self.ref = ref
        self.source = source
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.backgroundColor = .black
        view.addSubview(dim)
        dim.pin(to: view)

        scroll.delegate = self
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        scroll.pin(to: view)

        imageView.image = source?.image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        caption.text = ref.alt
        caption.textColor = UIColor(white: 1, alpha: 0.85)
        caption.font = .systemFont(ofSize: 14, weight: .medium)
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)

        var c = UIButton.Configuration.filled()
        c.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        c.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        close.configuration = c
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        // Load full resolution behind the thumbnail.
        Task {
            if let full = await ImageLoader.shared.load(ref.url, maxPixel: 2400) {
                UIView.transition(with: imageView, duration: 0.2, options: .transitionCrossDissolve) { self.imageView.image = full }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.zoomScale == 1 { imageView.frame = scroll.bounds }
    }

    func fittedFrame() -> CGRect {
        let b = view.bounds
        let w = b.width, h = w * ref.aspect
        return CGRect(x: 0, y: max(0, (b.height - h) / 2), width: w, height: min(h, b.height))
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(origin: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), size: size), animated: true)
        }
    }

    @objc private func drag(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        let progress = min(1, abs(t.y) / 400)
        switch g.state {
        case .changed:
            let s = 1 - progress * 0.25
            imageView.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: s, y: s)
            dim.alpha = 1 - progress * 1.2
            caption.alpha = 1 - progress * 3
            close.alpha = caption.alpha
        case .ended, .cancelled:
            let v = g.velocity(in: view).y
            if abs(t.y) > 120 || abs(v) > 900 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                    self.dim.alpha = 1; self.caption.alpha = 1; self.close.alpha = 1
                }
            }
        default: break
        }
    }

    // MARK: Transition

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        HeroTransition(presenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        HeroTransition(presenting: false)
    }

    fileprivate var sourceView: UIImageView? { source }
    fileprivate var dimView: UIView { dim }
    fileprivate var chrome: [UIView] { [caption, close] }
}

extension ImageViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        return scroll.zoomScale == 1 && abs(v.y) > abs(v.x)
    }
}

/// Image flies between its thumbnail and full screen on a spring.
private final class HeroTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { presenting ? 0.5 : 0.42 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let viewer = ctx.viewController(forKey: key) as? ImageViewerController else { ctx.completeTransition(true); return }
        let container = ctx.containerView
        if presenting { container.addSubview(viewer.view); viewer.view.frame = container.bounds; viewer.view.layoutIfNeeded() }

        let source = viewer.sourceView
        let sourceFrame = source.map { $0.convert($0.bounds, to: container) } ?? viewer.fittedFrame().insetBy(dx: 40, dy: 40)
        let full = viewer.view.convert(viewer.fittedFrame(), to: container)

        let flier = UIImageView(image: viewer.imageView.image ?? source?.image)
        flier.contentMode = .scaleAspectFill
        flier.clipsToBounds = true
        flier.layer.cornerCurve = .continuous
        flier.frame = presenting ? sourceFrame : full
        flier.layer.cornerRadius = presenting ? 16 : 0
        container.addSubview(flier)
        viewer.imageView.isHidden = true
        source?.alpha = 0
        if presenting { viewer.dimView.alpha = 0; viewer.chrome.forEach { $0.alpha = 0 } }

        let anim = UIViewPropertyAnimator(duration: transitionDuration(using: ctx), dampingRatio: presenting ? 0.82 : 0.9) {
            flier.frame = self.presenting ? full : sourceFrame
            flier.layer.cornerRadius = self.presenting ? 0 : 16
            viewer.dimView.alpha = self.presenting ? 1 : 0
            viewer.chrome.forEach { $0.alpha = self.presenting ? 1 : 0 }
        }
        anim.addCompletion { _ in
            source?.alpha = 1
            viewer.imageView.isHidden = false
            flier.removeFromSuperview()
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
        anim.startAnimation()
    }
}
