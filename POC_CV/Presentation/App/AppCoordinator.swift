import UIKit

final class AppCoordinator: BaseCoordinator {
    private let window: UIWindow
    private let router: Routable

    init(window: UIWindow) {
        self.window = window
        self.router = Router()
    }

    override func start() {
        window.rootViewController = router.rootViewController
        window.makeKeyAndVisible()
        showHome()
    }

    private func showHome() {
        let coordinator = HomeCoordinator(router: router)
        addDependency(coordinator)

        coordinator.onFinish = { [weak self, weak coordinator] in
            self?.removeDependency(coordinator)
        }

        coordinator.start()
    }
}
