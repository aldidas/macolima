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

/// Classic three panes: sidebar, list, detail.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: SidebarItem? = .containers
    @State private var containerID: String?
    @State private var imageIDs: Set<String> = []
    @State private var volumeNames: Set<String> = []

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            VStack(spacing: 0) {
                StaleBanner()
                list
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 560)
    }

    @ViewBuilder private var list: some View {
        if !model.isBootstrapped {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch section ?? .containers {
            case .containers: ContainersView(selection: $containerID)
            case .images: ImagesView(selection: $imageIDs)
            case .volumes: VolumesView(selection: $volumeNames)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .containers {
        case .containers: ContainerDetailView(containerID: containerID)
        case .images: ImageDetailView(selection: imageIDs)
        case .volumes: VolumeDetailView(selection: volumeNames)
        }
    }
}
