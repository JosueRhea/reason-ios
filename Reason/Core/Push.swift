import UIKit
import UserNotifications

/// Push notifications. Reason sends workspace events to a small relay (see /relay) as signed webhooks;
/// the relay turns finished turns and input requests into APNs pushes for the phones registered here.
@MainActor
final class Push: NSObject {
    static let shared = Push()
    static let relay = URL(string: "https://reason-push.searchmateapp.workers.dev")!
    static let changed = Notification.Name("reason.push.changed")

    enum Status { case on, off, notAsked }
    private(set) var status: Status = .notAsked
    private var pendingRoute: [AnyHashable: Any]?
    private let defaults = UserDefaults.standard

    #if DEBUG
    private let apnsEnv = "sandbox"
    #else
    private let apnsEnv = "production"
    #endif

    /// Call once at launch, before the first scene connects, so taps that launched the app are delivered.
    func install() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired],
                                         icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground],
                                        icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "REQUEST_APPROVE", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REQUEST_OPEN", actions: [open], intentIdentifiers: []),
        ])
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        let new: Status = switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .on
        case .denied: .off
        default: .notAsked
        }
        let flipped = new != status
        status = new
        if new == .on { UIApplication.shared.registerForRemoteNotifications() }
        if flipped { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Asks once, the first time you land in the app signed in. Afterwards only the Profile row asks.
    func askOnce() {
        guard !defaults.bool(forKey: "push.asked") else { Task { await refreshStatus() }; return }
        defaults.set(true, forKey: "push.asked")
        Task { _ = await request() }
    }

    @discardableResult
    func request() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return granted
    }

    /// Asks the first time; when turned off, explains and offers Settings.
    func ensure(from vc: UIViewController?) async -> Bool {
        await refreshStatus()
        switch status {
        case .on: return true
        case .notAsked: return await request()
        case .off:
            guard let vc else { return false }
            let a = UIAlertController(title: "Notifications are off",
                                      message: "Turn them on in Settings → Reason → Notifications to hear when a Reason replies or needs you.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Not Now", style: .cancel))
            let open = UIAlertAction(title: "Open Settings", style: .default) { _ in Permissions.openSettings() }
            a.addAction(open)
            a.preferredAction = open
            (vc.presentedViewController ?? vc).present(a, animated: true)
            return false
        }
    }

    // MARK: Relay

    func didRegister(token data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        // Re-send when the token changes, and once a day so the relay can heal a disabled webhook.
        let last = defaults.string(forKey: "push.token"), at = defaults.double(forKey: "push.sentAt")
        guard token != last || Date().timeIntervalSince1970 - at > 86_400 else { return }
        Task {
            do {
                _ = try await call("POST", "/v1/devices", body: ["token": token, "env": apnsEnv])
                defaults.set(token, forKey: "push.token")
                defaults.set(Date().timeIntervalSince1970, forKey: "push.sentAt")
            } catch {
                NSLog("push register failed: \(error)")
            }
        }
    }

    /// Before sign-out: stop pushes to this phone. Takes the key since the Keychain is about to be cleared.
    func unregister(key: String) {
        guard let token = defaults.string(forKey: "push.token") else { return }
        defaults.removeObject(forKey: "push.token")
        defaults.removeObject(forKey: "push.sentAt")
        Task { _ = try? await call("DELETE", "/v1/devices/\(token)", key: key) }
    }

    func sendTest() async throws {
        if defaults.string(forKey: "push.token") == nil { throw APIError(status: 0, message: "This iPhone isn't registered yet. Try again in a moment.") }
        _ = try await call("POST", "/v1/test")
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, key: String? = nil) async throws -> Data {
        guard let key = key ?? Keychain.load() else { throw APIError(status: 401, message: "Not signed in") }
        var r = URLRequest(url: Self.relay.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, res) = try await URLSession.shared.data(for: r)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: code, message: msg ?? "Relay error \(code)")
        }
        return data
    }

    // MARK: Routing

    #if DEBUG
    /// Test hook: behave as if this notification payload was just tapped.
    func debugTap(_ info: [AnyHashable: Any]) { open(info) }
    #endif

    /// The scene calls this once the main UI is up, to finish a tap that launched the app.
    func mainReady() {
        if let r = pendingRoute { pendingRoute = nil; open(r) }
    }

    fileprivate func open(_ info: [AnyHashable: Any]) {
        // The window may not be key yet when a tap brings the app back, so find it through the scene delegate.
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let window = (scene?.delegate as? SceneDelegate)?.window ?? scene?.windows.first,
              let nav = window.rootViewController as? UINavigationController,
              let state = AppState.shared, state.api.isConnected || state.me != nil else { pendingRoute = info; return }
        let reasonId = info["reason_id"] as? String, sessionId = info["session_id"] as? String
        if let chat = nav.topViewController as? ChatViewController, chat.shows(reasonId: reasonId, sessionId: sessionId),
           nav.presentedViewController == nil { return }
        Task {
            var reason = reasonId.flatMap { id in state.reasons.first { $0.id == id } }
            if reason == nil, let reasonId {
                if let all = try? await state.api.reasons() { state.remember(reasons: all) }
                reason = state.reasons.first { $0.id == reasonId }
            }
            let vc: ChatViewController
            if let reason { vc = ChatViewController(mode: .reason(reason)) }
            else if let sessionId { vc = ChatViewController(mode: .session(id: sessionId, title: info["session_title"] as? String ?? "Session")) }
            else { return }
            nav.presentedViewController?.dismiss(animated: false)
            nav.popToRootViewController(animated: false)
            nav.pushViewController(vc, animated: true)
        }
    }

    private func visibleChat() -> ChatViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let nav = scene?.windows.first(where: \.isKeyWindow)?.rootViewController as? UINavigationController
        guard nav?.presentedViewController == nil else { return nil }
        return nav?.topViewController as? ChatViewController
    }

    /// Allow / Deny straight from the notification.
    private func resolve(_ info: [AnyHashable: Any], action: String) async {
        guard let sid = info["session_id"] as? String, let rid = info["request_id"] as? String else { return }
        if AppState.shared == nil, let key = Keychain.load() { AppState.shared = AppState(api: ReasonAPI(apiKey: key)) }
        guard let state = AppState.shared else { return }
        do {
            try await state.ensureConnected()
            try await state.api.resolve(sid, request: rid, action: action)
        } catch {
            let c = UNMutableNotificationContent()
            c.title = "Couldn't \(action == "approve" ? "allow" : "deny") that"
            c.body = (error as? APIError)?.message ?? error.localizedDescription
            c.userInfo = info
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "resolve-\(rid)", content: c, trigger: nil))
        }
    }
}

extension Push: UNUserNotificationCenterDelegate {
    // Completion-handler forms, not `async`: the async variants hand the result back to UIKit
    // from a background thread, and UIKit asserts (crash) when a tapped notification's response
    // completes off the main thread. Every completion here is called on the main thread.

    /// In the app: stay quiet about the chat you're looking at (it updates live), banner everything else.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let reasonId = info["reason_id"] as? String, sessionId = info["session_id"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let chat = self.visibleChat(), chat.shows(reasonId: reasonId, sessionId: sessionId) {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    completionHandler([])
                } else {
                    completionHandler([.banner, .list, .sound])
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case "ALLOW", "DENY":
                    // Finish only after the answer lands, so a background launch stays alive for it.
                    Task { @MainActor in
                        await self.resolve(info, action: action == "ALLOW" ? "approve" : "deny")
                        completionHandler()
                    }
                case UNNotificationDismissActionIdentifier:
                    completionHandler()
                default:
                    self.open(info)
                    completionHandler()
                }
            }
        }
    }
}
