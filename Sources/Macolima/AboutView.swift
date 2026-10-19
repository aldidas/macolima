import SwiftUI

struct AboutView: View {
    static let disclaimer = "An unofficial, independent GUI for Colima. Not affiliated with or endorsed by the Colima project."

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Macolima").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text(Self.disclaimer)
                .font(.callout).multilineTextAlignment(.center).frame(width: 320)
            Divider().frame(width: 240)
            Text("MIT License · © 2026 Aldi Daswanto").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
