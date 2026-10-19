import SwiftUI
import MacolimaKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            Label(item.rawValue, systemImage: item.symbol)
                .badge(count(item))
                .tag(item)
        }
        .safeAreaInset(edge: .bottom) {
            ColimaStatusView()
                .padding(10)
        }
    }

    private func count(_ item: SidebarItem) -> Int {
        switch item {
        case .containers: model.containers.count
        case .images: model.images.count
        case .volumes: model.volumes.count
        }
    }
}
