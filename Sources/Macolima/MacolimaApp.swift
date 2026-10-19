import SwiftUI
import MacolimaKit

@main
struct MacolimaApp: App {
    @State private var model = AppModel(store: SnapshotStore(directory: MacolimaApp.supportDirectory))

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Macolima") { openWindow(id: "about") }
            }
        }
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
