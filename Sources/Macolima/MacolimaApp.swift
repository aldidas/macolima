import SwiftUI
import MacolimaKit

@main
struct MacolimaApp: App {
    @State private var model: AppModel

    @Environment(\.openWindow) private var openWindow

    init() {
        // Bootstrapped here rather than in a window's `.task`: the menubar keeps the model live with no window open.
        let model = AppModel(store: SnapshotStore(directory: MacolimaApp.supportDirectory))
        _model = State(initialValue: model)
        Task { await model.bootstrap() }
    }

    var body: some Scene {
        Window("Macolima", id: "main") {
            RootView()
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Macolima") { openWindow(id: "about") }
            }
        }
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
        Window("About Macolima", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macolima", isDirectory: true)
    }
}
