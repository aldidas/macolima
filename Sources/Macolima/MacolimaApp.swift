import SwiftUI
import MacolimaKit

@main
struct MacolimaApp: App {
    @State private var model = AppModel(store: SnapshotStore(directory: MacolimaApp.supportDirectory))

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macolima", isDirectory: true)
    }
}
