import Foundation

final class HomeCoordinator: BaseCoordinator {
    private let router: Routable

    init(router: Routable) {
        self.router = router
    }

    override func start() {
        let viewModel = HomeViewModel()
        let viewController = HomeViewController(viewModel: viewModel)

        router.setRootModule(viewController, hideBar: true)
    }
}
