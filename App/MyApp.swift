import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // One window, because the indexing loops and the database belong to the whole app.
        Window("FindIt", id: "main") {
            ContentView(model: model)
        }
    }
}
