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
                if case .colimaStopped = model.connection, !model.colimaMissing {
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
        if model.colimaMissing, model.connection != .live {
            return "Colima is not installed. Install it with “brew install colima”, then press Retry."
        }
        switch model.connection {
        case .live:
            return nil
        case .colimaStopped(let last):
            return "Colima is stopped. " + Self.asOf(last, fallback: "No saved data yet.")
        case .stale(let date):
            return "Docker is not responding. " + Self.asOf(date == .distantPast ? nil : date, fallback: "No saved data yet.")
        case .unreachable(let message):
            return message
        }
    }

    private static func asOf(_ date: Date?, fallback: String) -> String {
        guard let date else { return fallback }
        return "Showing data as of \(date.formatted(date: .abbreviated, time: .shortened)); actions are disabled."
    }
}
