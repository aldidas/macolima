import SwiftUI
import MacolimaKit

enum Bytes {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Colima state pinned at the bottom of the sidebar: VM status and Docker's disk numbers next to the Mac's.
struct ColimaStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(running ? "Colima running" : (model.colimaMissing ? "Colima not found" : "Colima stopped")).font(.headline)
            }
            if case .running(let info) = model.colima {
                Text("\(info.cpus) CPU · \(Bytes.string(info.memoryBytes)) RAM")
                    .font(.caption).foregroundStyle(.secondary)
            }
            diskLines
            if model.colimaMissing {
                Text("Not installed: brew install colima").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(running ? "Stop Colima" : "Start Colima") {
                    Task { running ? await model.stopColima() : await model.startColima() }
                }
                .controlSize(.small)
                .disabled(model.colimaBusy)
            }
            if model.colimaBusy { ProgressView().controlSize(.small) }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var running: Bool {
        if case .running = model.colima { true } else { false }
    }

    @ViewBuilder private var diskLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VM disk").font(.caption.weight(.semibold))
            if let docker = model.dockerBytes {
                Text("Docker: \(Bytes.string(docker)) used").font(.caption)
            }
            if let disk = model.hostDisk {
                let max = disk.maxBytes.map { " of \(Bytes.string($0)) max" } ?? ""
                Text("Mac: \(Bytes.string(disk.allocatedBytes)) allocated\(max)").font(.caption)
            }
        }
        .foregroundStyle(.secondary)
        .help("Deleting images or volumes frees space inside the VM, but the disk image on your Mac may not shrink.")
    }
}
