import SwiftUI
import MacolimaKit

/// Shown whenever the data on screen is not live. Explains why and offers the obvious next action.
struct StaleBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text).font(.callout)
                Spacer()
                if case .colimaStopped = model.connection {
                    Button("Start Colima") { Task { await model.startColima() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.colimaBusy)
                } else {
                    Button("Retry") { Task { await model.reconnect() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var text: String? {
        switch model.connection {
        case .live:
            nil
        case .colimaStopped(let last):
            "Colima is stopped. " + Self.asOf(last, fallback: "No saved data yet.")
        case .stale(let date):
            "Docker is not responding. " + Self.asOf(date == .distantPast ? nil : date, fallback: "No saved data yet.")
        case .unreachable(let message):
            message
        }
    }

    private static func asOf(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback }
        return "Showing data as of \(date.formatted(date: .abbreviated, time: .shortened)); actions are disabled."
    }
}
