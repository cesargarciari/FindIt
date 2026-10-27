import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let library = model.library {
                LibraryView(library: library)
            } else {
                SetupView(model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .task { await model.launch() }
    }
}
