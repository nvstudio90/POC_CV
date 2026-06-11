import Foundation

class BaseCoordinator: Coordinator {
    var childCoordinators: [Coordinator] = []
    var onFinish: (() -> Void)?

    func start() {
        fatalError("Subclasses must override start()")
    }

    func addDependency(_ coordinator: Coordinator) {
        guard childCoordinators.contains(where: { $0 === coordinator }) == false else {
            return
        }

        childCoordinators.append(coordinator)
    }

    func removeDependency(_ coordinator: Coordinator?) {
        guard
            let coordinator,
            let index = childCoordinators.firstIndex(where: { $0 === coordinator })
        else {
            return
        }

        childCoordinators.remove(at: index)
    }

    func finish() {
        onFinish?()
        onFinish = nil
    }
}
