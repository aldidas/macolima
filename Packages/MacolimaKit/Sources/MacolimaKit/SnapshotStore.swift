import Foundation

public struct SnapshotStore: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent("snapshot.json")
    }

    public func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }

    /// A missing, unreadable or schema-mismatched file is `nil`, never a crash.
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
