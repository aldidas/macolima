import XCTest
@testable import MacolimaKit

final class SnapshotStoreTests: XCTestCase {
    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macolima-snap-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private var sample: Snapshot {
        Snapshot(savedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 containers: [container("web", project: "shop", volumes: ["pgdata"])],
                 images: [image("sha256:a", tags: ["alpine:latest"], size: 8_000_000)],
                 volumes: [volume("pgdata", size: 42), volume("mystery", size: nil)])
    }

    func test_roundTrip() throws {
        let store = SnapshotStore(directory: makeDir())   // directory does not exist yet
        try store.save(sample)
        XCTAssertEqual(store.load(), sample)
    }

    func test_load_missingFile_isNil() {
        XCTAssertNil(SnapshotStore(directory: makeDir()).load())
    }

    func test_load_corruptFile_isNil() throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("snapshot.json"))
        XCTAssertNil(SnapshotStore(directory: dir).load())
    }

    func test_load_schemaMismatch_isNil() throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"savedAt":"yesterday","containers":42}"#.utf8).write(to: dir.appendingPathComponent("snapshot.json"))
        XCTAssertNil(SnapshotStore(directory: dir).load())
    }

    func test_save_overwritesPreviousSnapshot() throws {
        let store = SnapshotStore(directory: makeDir())
        try store.save(sample)
        let newer = Snapshot(savedAt: Date(timeIntervalSince1970: 1_800_000_999), containers: [], images: [], volumes: [])
        try store.save(newer)
        XCTAssertEqual(store.load(), newer)
    }
}
