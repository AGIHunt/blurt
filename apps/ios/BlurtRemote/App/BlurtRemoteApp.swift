import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting s: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let s = scene as? UIWindowScene else { return }
        let w = PadWindow(windowScene: s)
        w.rootViewController = PadViewController()
        w.backgroundColor = .black
        w.overrideUserInterfaceStyle = .dark
        window = w
        w.makeKeyAndVisible()
        if let u = options.urlContexts.first?.url { Link.shared.openExternal(u) }
    }

    func scene(_ scene: UIScene, openURLContexts c: Set<UIOpenURLContext>) {
        if let u = c.first?.url { Link.shared.openExternal(u) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { Link.shared.foreground() }
    func sceneWillResignActive(_ scene: UIScene) { Link.shared.leaving() }
    func sceneDidEnterBackground(_ scene: UIScene) { Link.shared.background() }
}
