import Foundation

final class HomeCoordinator: BaseCoordinator {
    private let router: Routable

    init(router: Routable) {
        self.router = router
    }

    override func start() {
        let viewModel = HomeViewModel()
        if let videoURL = resolveInitialVideoURL() {
            viewModel.setVideoURL(videoURL)
        }
        let viewController = HomeViewController(viewModel: viewModel)

        router.setRootModule(viewController, hideBar: true)
    }

    private func resolveInitialVideoURL() -> URL? {
        return Bundle.main.url(forResource: "test", withExtension: "MOV")
    }
}
