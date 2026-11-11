import AVFoundation
import UIKit

/// Microphone / camera access, with a way back to Settings when it was turned off.
@MainActor
enum Permissions {
    enum Kind { case microphone, camera }
    enum Status { case granted, denied, notAsked }

    static func status(_ k: Kind) -> Status {
        switch k {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .notAsked
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notAsked
            }
        }
    }

    /// Asks the first time; returns whether access is available now.
    static func request(_ k: Kind) async -> Bool {
        switch status(k) {
        case .granted: return true
        case .denied: return false
        case .notAsked:
            switch k {
            case .microphone: return await AVAudioApplication.requestRecordPermission()
            case .camera: return await AVCaptureDevice.requestAccess(for: .video)
            }
        }
    }

    /// Ensures access, or explains and offers Settings. Returns true when you may proceed.
    static func ensure(_ k: Kind, from vc: UIViewController?) async -> Bool {
        if await request(k) { return true }
        guard let vc else { return false }
        let (title, message): (String, String) = {
            switch k {
            case .microphone: return ("Microphone is off",
                                      "Reason needs the microphone to turn your voice into a message. Turn it on in Settings → Reason → Microphone.")
            case .camera: return ("Camera is off",
                                  "Reason needs the camera to attach photos and videos. Turn it on in Settings → Reason → Camera.")
            }
        }()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        let open = UIAlertAction(title: "Open Settings", style: .default) { _ in openSettings() }
        a.addAction(open)
        a.preferredAction = open
        (vc.presentedViewController ?? vc).present(a, animated: true)
        return false
    }

    /// The app's own page in Settings.
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
