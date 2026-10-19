import XCTest
@testable import MacolimaKit

final class ColimaTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/x")

    // MARK: SocketLocator

    func test_resolve_usesDockerContextEndpoint() async {
        let info = await SocketLocator.resolve(run: { exe, args in
            XCTAssertEqual(exe, "docker")
            XCTAssertEqual(args.prefix(2), ["context", "inspect"])
            return "unix:///Users/x/.colima/default/docker.sock\n"
        }, home: home)
        XCTAssertEqual(info, SocketInfo(path: "/Users/x/.colima/default/docker.sock", profile: "default"))
    }

    func test_resolve_profileFromPathSegment() async {
        let info = await SocketLocator.resolve(run: { _, _ in "unix:///Users/x/.colima/work/docker.sock" }, home: home)
        XCTAssertEqual(info, SocketInfo(path: "/Users/x/.colima/work/docker.sock", profile: "work"))
    }

    func test_resolve_fallsBackToDefaultWhenDockerMissing() async {
        struct Missing: Error {}
        let info = await SocketLocator.resolve(run: { _, _ in throw Missing() }, home: home)
        XCTAssertEqual(info, SocketInfo(path: "/Users/x/.colima/default/docker.sock", profile: "default"))
    }

    func test_resolve_nonUnixEndpoint_fallsBack() async {
        let info = await SocketLocator.resolve(run: { _, _ in "tcp://10.0.0.1:2375" }, home: home)
        XCTAssertEqual(info.path, "/Users/x/.colima/default/docker.sock")
    }

    // MARK: ColimaService status / control

    func test_status_notRunning_isStopped() async {
        let svc = ColimaService(profile: "default", home: home, run: { _, _ in
            throw ShellError.failed(exe: "colima", code: 1, stderr: "colima [profile=default] is not running")
        })
        let status = await svc.status()
        XCTAssertEqual(status, .stopped)
    }

    func test_status_parsesRunningJSON() async throws {
        let json = String(decoding: Fixture.data("colima_status"), as: UTF8.self)
        let calls = CallLog()
        let svc = ColimaService(profile: "work", home: home, run: { exe, args in
            await calls.add(exe, args)
            return json
        })
        let status = await svc.status()
        guard case .running(let info) = status else { return XCTFail("expected running, got \(status)") }
        XCTAssertEqual(info.cpus, 4)
        XCTAssertEqual(info.memoryBytes, 8_589_934_592)
        XCTAssertEqual(info.diskMaxBytes, 64_424_509_440)
        XCTAssertEqual(info.runtime, "docker")
        let recorded = await calls.list
        XCTAssertEqual(recorded, [["colima", "status", "--json", "-p", "work"]])
    }

    func test_status_garbageOutput_isStopped() async {
        let svc = ColimaService(profile: "default", home: home, run: { _, _ in "not json" })
        let status = await svc.status()
        XCTAssertEqual(status, .stopped)
    }

    func test_startStop_passProfile() async throws {
        let calls = CallLog()
        let svc = ColimaService(profile: "work", home: home, run: { exe, args in await calls.add(exe, args); return "" })
        try await svc.start()
        try await svc.stop()
        let recorded = await calls.list
        XCTAssertEqual(recorded, [["colima", "start", "-p", "work"], ["colima", "stop", "-p", "work"]])
    }

    // MARK: Host disk

    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macolima-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 1 GB apparent size, ~4 KB actually written.
    private func makeSparse(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 4096))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 1 << 30)
        try h.close()
    }

    func test_hostDisk_reportsAllocatedNotApparentSize() throws {
        let home = try makeHome()
        try makeSparse(home.appendingPathComponent(".colima/_lima/colima/diffdisk"))
        let disk = ColimaService(profile: "default", home: home).hostDisk()
        XCTAssertNotNil(disk)
        XCTAssertGreaterThan(disk!.allocatedBytes, 0)
        XCTAssertLessThan(disk!.allocatedBytes, 1_000_000)
        XCTAssertNil(disk!.maxBytes)
        XCTAssertEqual(ColimaService(profile: "default", home: home).hostDisk(maxBytes: 64)?.maxBytes, 64)
    }

    func test_hostDisk_sumsInstanceDiskAndDataDisk_forNamedProfile() throws {
        let home = try makeHome()
        try makeSparse(home.appendingPathComponent(".colima/_lima/colima-work/disk"))
        try makeSparse(home.appendingPathComponent(".colima/_lima/_disks/colima-work/datadisk"))
        try makeSparse(home.appendingPathComponent(".colima/_lima/colima/disk"))   // other profile, must be ignored
        let both = ColimaService(profile: "work", home: home).hostDisk()!.allocatedBytes
        let one = try allocated(home.appendingPathComponent(".colima/_lima/colima-work/disk"))
        XCTAssertEqual(both, one * 2)
    }

    func test_hostDisk_nothingFound_isNil() throws {
        XCTAssertNil(ColimaService(profile: "default", home: try makeHome()).hostDisk())
    }

    private func allocated(_ url: URL) throws -> Int64 {
        var st = stat()
        XCTAssertEqual(stat(url.path, &st), 0)
        return Int64(st.st_blocks) * 512
    }

    // MARK: Shell

    func test_shell_runReturnsStdout_andThrowsOnFailure() async throws {
        let out = try await Shell.run("echo", ["hi"])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
        do {
            _ = try await Shell.run("sh", ["-c", "echo oops >&2; exit 3"])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? ShellError, .failed(exe: "sh", code: 3, stderr: "oops"))
        }
        do {
            _ = try await Shell.run("definitely-not-a-real-binary-xyz", [])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? ShellError, .notFound("definitely-not-a-real-binary-xyz"))
        }
    }
}

private actor CallLog {
    private(set) var list: [[String]] = []
    func add(_ exe: String, _ args: [String]) { list.append([exe] + args) }
}
