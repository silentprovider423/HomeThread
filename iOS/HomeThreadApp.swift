import SwiftUI

@main
struct HomeThreadApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRoot().environment(model)
        }
    }
}
