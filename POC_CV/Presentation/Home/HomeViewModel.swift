import Foundation

protocol HomeViewModelProtocol {
    var title: String { get }
}

struct HomeViewModel: HomeViewModelProtocol {
    let title = "Home"
}
