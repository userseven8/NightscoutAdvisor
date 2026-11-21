import SwiftUI

@main
struct NightscoutAdvisorApp: App {
    @StateObject private var viewModel = AdvisorViewModel()

    var body: some Scene {
        WindowGroup {
            RootContentView(viewModel: viewModel)
        }
    }
}
