import SwiftUI
import MacolimaKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .containers

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                StaleBanner()
                content
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder private var content: some View {
        if !model.isBootstrapped {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch selection ?? .containers {
            case .containers: ContentUnavailableView("Containers", systemImage: SidebarItem.containers.symbol)
            case .images: ContentUnavailableView("Images", systemImage: SidebarItem.images.symbol)
            case .volumes: ContentUnavailableView("Volumes", systemImage: SidebarItem.volumes.symbol)
            }
        }
    }
}
