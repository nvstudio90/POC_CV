import UIKit

protocol Routable: AnyObject {
    var rootViewController: UIViewController { get }

    func setRootModule(_ module: UIViewController, hideBar: Bool)
    func push(_ module: UIViewController, animated: Bool, onPop: (() -> Void)?)
    func popModule(animated: Bool)
    func present(_ module: UIViewController, animated: Bool, completion: (() -> Void)?)
    func dismissModule(animated: Bool, completion: (() -> Void)?)
}

final class Router: NSObject, Routable {
    let rootViewController: UIViewController

    private let navigationController: UINavigationController
    private var completions: [ObjectIdentifier: () -> Void] = [:]

    init(rootViewController: UINavigationController = UINavigationController()) {
        navigationController = rootViewController
        self.rootViewController = rootViewController
        super.init()
        navigationController.delegate = self
    }

    func setRootModule(_ module: UIViewController, hideBar: Bool = true) {
        clearCompletions()
        navigationController.setNavigationBarHidden(hideBar, animated: false)
        navigationController.setViewControllers([module], animated: false)
    }

    func push(_ module: UIViewController, animated: Bool = true, onPop: (() -> Void)? = nil) {
        let key = ObjectIdentifier(module)
        completions[key] = onPop
        navigationController.pushViewController(module, animated: animated)
    }

    func popModule(animated: Bool = true) {
        if let controller = navigationController.topViewController {
            runCompletion(for: controller)
        }

        navigationController.popViewController(animated: animated)
    }

    func present(_ module: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
        let key = ObjectIdentifier(module)
        completions[key] = completion
        navigationController.present(module, animated: animated)
    }

    func dismissModule(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard let presentedViewController = navigationController.presentedViewController else {
            completion?()
            return
        }

        navigationController.dismiss(animated: animated) { [weak self] in
            self?.runCompletion(for: presentedViewController)
            completion?()
        }
    }

    private func clearCompletions() {
        completions.removeAll()
    }

    private func runCompletion(for viewController: UIViewController) {
        let key = ObjectIdentifier(viewController)
        let completion = completions.removeValue(forKey: key)
        completion?()
    }
}

extension Router: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard
            let fromViewController = navigationController.transitionCoordinator?.viewController(forKey: .from),
            navigationController.viewControllers.contains(fromViewController) == false
        else {
            return
        }

        runCompletion(for: fromViewController)
    }
}
