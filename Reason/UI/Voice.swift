import AVFoundation
import UIKit

/// Records AAC (m4a) with metering for the live waveform.
@MainActor
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("reason-dictation.m4a")
    static let contentType = "audio/mp4"
    static let maxDuration: TimeInterval = 120   // keeps uploads well under the 10 MiB limit

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }
    var isRecording: Bool { recorder?.isRecording ?? false }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record(forDuration: Self.maxDuration) else { throw APIError(status: 0, message: "Couldn't start recording") }
        recorder = r
    }

    /// 0…1 loudness, perceptually scaled.
    func level() -> CGFloat {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)          // -160…0
        let clamped = max(-50, db)
        return CGFloat(pow(10, clamped / 40))           // gentle curve so speech fills the range
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return try? Data(contentsOf: url)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Scrolling bar waveform, newest sample on the right — like a voice memo.
final class WaveformView: UIView {
    private var bars: [CALayer] = []
    private var samples: [CGFloat] = []
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 2.5
    private let edgeFade = CAGradientLayer()
    var color: UIColor = .label { didSet { bars.forEach { $0.backgroundColor = color.resolvedColor(with: traitCollection).cgColor } } }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Older samples fade out toward the left edge.
        edgeFade.colors = [UIColor.black.withAlphaComponent(0.15).cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        edgeFade.locations = [0, 0.3, 1]
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        edgeFade.frame = bounds
        layer.mask = edgeFade
        let count = max(1, Int((bounds.width + gap) / (barWidth + gap)))
        guard count != bars.count else { redraw(); return }
        bars.forEach { $0.removeFromSuperlayer() }
        bars = (0..<count).map { _ in
            let l = CALayer()
            l.backgroundColor = color.resolvedColor(with: traitCollection).cgColor
            l.cornerRadius = barWidth / 2
            layer.addSublayer(l)
            return l
        }
        samples = Array(repeating: 0, count: count)
        redraw()
    }

    func push(_ level: CGFloat) {
        guard !samples.isEmpty else { return }
        samples.removeFirst()
        samples.append(level)
        redraw()
    }

    func reset() {
        samples = Array(repeating: 0, count: samples.count)
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        let h = bounds.height
        for (i, l) in bars.enumerated() {
            let v = i < samples.count ? samples[i] : 0
            let bh = max(barWidth, min(h, h * v))
            l.frame = CGRect(x: CGFloat(i) * (barWidth + gap), y: (h - bh) / 2, width: barWidth, height: bh)
            l.opacity = Float(0.35 + 0.65 * min(1, v * 1.4))
        }
        CATransaction.commit()
    }

    /// Bars collapse to dots and ripple while we wait for the transcript.
    func startProcessing() {
        let now = CACurrentMediaTime()
        for (i, l) in bars.enumerated() {
            l.removeAllAnimations()
            l.frame = CGRect(x: l.frame.minX, y: (bounds.height - barWidth) / 2, width: barWidth, height: barWidth)
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1, 3.2, 1]
            a.keyTimes = [0, 0.5, 1]
            a.duration = 0.9
            a.repeatCount = .infinity
            a.beginTime = now + Double(i) * 0.03
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "wave")
        }
    }

    func stopProcessing() { bars.forEach { $0.removeAllAnimations() } }
}
