import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Push.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("APNs registration failed: \(error)")
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.tintColor = .label
        window = w
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugGallery") {
            w.rootViewController = UINavigationController(rootViewController: DebugGalleryViewController())
            w.makeKeyAndVisible()
            return
        }
        #endif
        if let key = Keychain.load() {
            let state = AppState(api: ReasonAPI(apiKey: key))
            AppState.shared = state
            showMain(state, connecting: true)
        } else {
            showOnboarding()
        }
        w.makeKeyAndVisible()
    }

    func showOnboarding() {
        LiveHub.shared.stop()
        DiskCache.clear()
        let vc = OnboardingViewController()
        vc.onConnected = { [weak self] state in self?.showMain(state, connecting: false) }
        swapRoot(vc)
    }

    /// No splash: the list renders from the disk cache on the first frame, then refreshes.
    private func showMain(_ state: AppState, connecting: Bool) {
        AppState.shared = state
        window?.backgroundColor = Theme.background
        let nav = UINavigationController(rootViewController: ReasonsListViewController())
        swapRoot(nav)
        #if DEBUG
        // Read-only screenshot aid: launch straight into a Session (`-debugOpenSession <id>`).
        if let sid = UserDefaults.standard.string(forKey: "debugOpenSession") {
            nav.pushViewController(ChatViewController(mode: .session(id: sid, title: "Session")), animated: false)
        }
        #endif
        Task { @MainActor in
            do {
                try await state.ensureConnected()
                // Re-check the key in the background even when the org came from cache.
                if connecting { state.me = try await state.api.connect(); DiskCache.save("self", state.me!) }
                LiveHub.shared.start(api: state.api)
                Push.shared.askOnce()
                Push.shared.mainReady()
            } catch let e as APIError where e.status == 401 || e.status == 403 {
                Keychain.delete()
                DiskCache.clear()
                showOnboarding()
            } catch {
                LiveHub.shared.start(api: state.api)   // offline: the stream reconnects on its own
                Push.shared.mainReady()
            }
        }
    }

    // Streams don't survive suspension: close them in the background, reopen and refresh on return.
    func sceneDidEnterBackground(_ scene: UIScene) {
        LiveHub.shared.stop()
    }

    /// A notification tap that arrived before the UI was ready is finished here.
    func sceneDidBecomeActive(_ scene: UIScene) {
        Push.shared.mainReady()
        #if DEBUG
        if let rid = UserDefaults.standard.string(forKey: "debugTapReason") {
            UserDefaults.standard.removeObject(forKey: "debugTapReason")
            Push.shared.debugTap(["reason_id": rid, "session_id": "x"])
            // Timing aid: leave and reopen the chat warm, like a second tap from the list.
            if UserDefaults.standard.bool(forKey: "debugReopen") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    (self?.window?.rootViewController as? UINavigationController)?.popToRootViewController(animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Push.shared.debugTap(["reason_id": rid, "session_id": "x"]) }
                }
            }
        }
        #endif
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        guard let state = AppState.shared, state.api.isConnected else { return }
        LiveHub.shared.start(api: state.api)
        NotificationCenter.default.post(name: LiveHub.resumed, object: nil)
        Task { await Push.shared.refreshStatus() }
    }

    private func swapRoot(_ vc: UIViewController) {
        guard let w = window else { return }
        if w.rootViewController == nil { w.rootViewController = vc; return }
        UIView.transition(with: w, duration: 0.35, options: .transitionCrossDissolve) {
            w.rootViewController = vc
        }
    }
}
