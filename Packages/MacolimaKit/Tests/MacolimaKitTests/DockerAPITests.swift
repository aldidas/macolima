import XCTest
@testable import MacolimaKit

final class DockerAPITests: XCTestCase {
    private let composeID = String(repeating: "a", count: 64)
    private let nameless = "0123456789abcdef" + String(repeating: "0", count: 48)

    func test_negotiate_usesServerAPIVersionInLaterPaths() async throws {
        let t = FakeTransport.standard()
        let api = DockerAPI(transport: t)
        try await api.negotiate()
        _ = try await api.containers()
        XCTAssertEqual(t.requests.map(\.path), ["/version", "/v1.47/containers/json"])
    }

    func test_containers_requestsAll() async throws {
        let t = FakeTransport.standard()
        _ = try await DockerAPI(transport: t).containers()
        XCTAssertEqual(t.requests.last?.query, ["all": "1"])
    }

    func test_containers_mapsFirstNameWithoutSlash() async throws {
        let c = try await DockerAPI(transport: FakeTransport.standard()).containers().first { $0.id == composeID }
        XCTAssertEqual(c?.name, "first-name")
        XCTAssertEqual(c?.state, .running)
        XCTAssertEqual(c?.imageID, "sha256:" + String(repeating: "1", count: 64))
        XCTAssertEqual(c?.ports.first, PortMapping(privatePort: 80, publicPort: 8080, type: "tcp"))
        XCTAssertEqual(c?.ports.last, PortMapping(privatePort: 9000, publicPort: nil, type: "tcp"))
        XCTAssertEqual(c?.created, Date(timeIntervalSince1970: 1760000000))
    }

    func test_containers_fallsBackToShortIDWhenNoName() async throws {
        let c = try await DockerAPI(transport: FakeTransport.standard()).containers().first { $0.id == nameless }
        XCTAssertEqual(c?.name, "0123456789ab")
        XCTAssertEqual(c?.state, .exited)
    }

    func test_containers_extractsComposeLabels() async throws {
        let all = try await DockerAPI(transport: FakeTransport.standard()).containers()
        let c = all.first { $0.id == composeID }
        XCTAssertEqual(c?.composeProject, "shop")
        XCTAssertEqual(c?.composeService, "web")
        XCTAssertNil(all.first { $0.id == nameless }?.composeProject)
    }

    func test_containers_collectsNamedVolumeMountsOnly() async throws {
        let c = try await DockerAPI(transport: FakeTransport.standard()).containers().first { $0.id == composeID }
        XCTAssertEqual(c?.volumeNames, ["shop_pgdata"])
    }

    func test_images_danglingImageHasEmptyTags() async throws {
        let images = try await DockerAPI(transport: FakeTransport.standard()).images()
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images[0].tags, ["alpine:latest"])
        XCTAssertEqual(images[1].tags, [])      // RepoTags: null
        XCTAssertEqual(images[2].tags, [])      // RepoTags: ["<none>:<none>"]
        XCTAssertEqual(images[0].size, 8123456)
    }

    func test_volumes_mergesSizeFromDF_andMapsMinusOneToNil() async throws {
        let vols = try await DockerAPI(transport: FakeTransport.standard()).volumes()
        XCTAssertEqual(vols.first { $0.name == "shop_pgdata" }?.size, 123456789)
        XCTAssertNil(vols.first { $0.name == "scratch" }?.size)
        XCTAssertNotNil(vols.first { $0.name == "scratch" }?.createdAt)
    }

    func test_volumes_cachesSystemDFForFiveSeconds() async throws {
        let t = FakeTransport.standard()
        let clock = TestClock()
        let api = DockerAPI(transport: t, now: { clock.now() })
        _ = try await api.volumes()
        clock.advance(4)
        _ = try await api.volumes()
        XCTAssertEqual(t.requests.filter { $0.path.hasSuffix("/system/df") }.count, 1)
        clock.advance(2)
        _ = try await api.volumes()
        XCTAssertEqual(t.requests.filter { $0.path.hasSuffix("/system/df") }.count, 2)
    }

    func test_removeContainer_sendsDELETE_withV0Force0() async throws {
        let t = FakeTransport.standard()
        try await DockerAPI(transport: t).removeContainer("abc")
        let r = t.requests.last
        XCTAssertEqual(r?.method, "DELETE")
        XCTAssertEqual(r?.path, "/v1.47/containers/abc")
        XCTAssertEqual(r?.query, ["v": "0", "force": "0"])
    }

    func test_removeImage_neverSendsForce1() async throws {
        let t = FakeTransport.standard()
        try await DockerAPI(transport: t).removeImage("sha256:abc")
        let r = t.requests.last
        XCTAssertEqual(r?.method, "DELETE")
        XCTAssertEqual(r?.path, "/v1.47/images/sha256:abc")
        XCTAssertEqual(r?.query, ["force": "0", "noprune": "0"])
    }

    func test_removeVolume_neverSendsForce1() async throws {
        let t = FakeTransport.standard()
        try await DockerAPI(transport: t).removeVolume("scratch")
        let r = t.requests.last
        XCTAssertEqual(r?.method, "DELETE")
        XCTAssertEqual(r?.path, "/v1.47/volumes/scratch")
        XCTAssertEqual(r?.query, ["force": "0"])
    }

    func test_startStopRestart_postToContainerActions() async throws {
        let t = FakeTransport.standard()
        let api = DockerAPI(transport: t)
        try await api.start("c1"); try await api.stop("c1"); try await api.restart("c1")
        let calls = t.requests.suffix(3)
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(calls.map(\.path), ["/v1.47/containers/c1/start", "/v1.47/containers/c1/stop", "/v1.47/containers/c1/restart"])
    }

    func test_isTTY_readsConfigTty() async throws {
        let t = FakeTransport { req in
            if req.path.hasSuffix("/version") { return HTTPResponse(status: 200, headers: [:], body: Fixture.data("version")) }
            return HTTPResponse(status: 200, headers: [:], body: Data(#"{"Config":{"Tty":true}}"#.utf8))
        }
        let tty = try await DockerAPI(transport: t).isTTY(containerID: "c1")
        XCTAssertTrue(tty)
        XCTAssertEqual(t.requests.last?.path, "/v1.47/containers/c1/json")
    }

    func test_events_decodesNDJSONLines() async throws {
        let t = FakeTransport.standard()
        let l1 = #"{"Type":"container","Action":"start","Actor":{"ID":"abc","Attributes":{}}}"# + "\n"
        let l2 = #"{"Type":"volume","Action":"create","Actor":{"ID":"pgdata"}}"# + "\n"
        let l3 = #"{"Type":"network","Action":"connect","Actor":{"ID":"n1"}}"# + "\n"
        let l4 = #"{"Type":"image","Action":"delete","Actor":{"ID":"sha256:ff"}}"# + "\n"
        // second line split across two reads
        t.streamChunks = [Data((l1 + l2.prefix(20)).utf8), Data((String(l2.dropFirst(20)) + l3 + l4).utf8)]
        var events: [DockerEvent] = []
        for try await e in DockerAPI(transport: t).events() { events.append(e) }
        XCTAssertEqual(events, [
            .container(id: "abc", action: "start"),
            .volume(name: "pgdata", action: "create"),
            .other,
            .image(id: "sha256:ff", action: "delete"),
        ])
    }

    func test_diskUsage_sumsLayersVolumesBuildCacheAndWritableLayers() async throws {
        // 64_000_000 layers + 123_456_789 volume (the -1 volume is ignored) + 2_000 build cache + 1_000 container
        let bytes = try await DockerAPI(transport: FakeTransport.standard()).diskUsage()
        XCTAssertEqual(bytes, 64_000_000 + 123_456_789 + 2_000 + 1_000)
    }

    func test_diskUsage_sharesTheCachedSystemDF() async throws {
        let t = FakeTransport.standard()
        let api = DockerAPI(transport: t)
        _ = try await api.volumes()
        _ = try await api.diskUsage()
        XCTAssertEqual(t.requests.filter { $0.path.hasSuffix("/system/df") }.count, 1)
    }

    func test_slowCalls_getALongerTimeoutThanReads() async throws {
        let t = FakeTransport.standard()
        let api = DockerAPI(transport: t)
        try await api.stop("c1")
        XCTAssertEqual(t.requests.last?.timeout, 120, "stop waits for the container's grace period")
        _ = try await api.volumes()
        XCTAssertEqual(t.requests.last { $0.path.hasSuffix("/system/df") }?.timeout, 120, "/system/df is slow on big hosts")
        _ = try await api.containers()
        XCTAssertNil(t.requests.last?.timeout, "plain reads use the transport default")
    }

    /// Review finding: healthchecks emit exec_* / health_status every few seconds; they must not look like state changes.
    func test_events_chattyNonStateEventsAreOther() async throws {
        let t = FakeTransport.standard()
        func line(_ action: String) -> String { #"{"Type":"container","Action":"\#(action)","Actor":{"ID":"abc"}}"# + "\n" }
        t.streamChunks = [Data((["exec_create: sh -c true", "exec_start: sh -c true", "exec_die", "health_status: healthy",
                                  "attach", "resize", "top", "start"].map(line)).joined().utf8)]
        var events: [DockerEvent] = []
        for try await e in DockerAPI(transport: t).events() { events.append(e) }
        XCTAssertEqual(events, Array(repeating: DockerEvent.other, count: 7) + [.container(id: "abc", action: "start")])
    }
}
