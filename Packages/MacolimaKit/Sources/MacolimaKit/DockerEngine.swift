import Foundation

public enum DockerEvent: Sendable, Equatable {
    case container(id: String, action: String)
    case image(id: String, action: String)
    case volume(name: String, action: String)
    case other
}

public protocol DockerEngine: Sendable {
    func negotiate() async throws
    func containers() async throws -> [ContainerSummary]
    func images() async throws -> [ImageSummary]
    /// Sizes are merged from `/system/df`.
    func volumes() async throws -> [VolumeSummary]
    func start(_ id: String) async throws
    func stop(_ id: String) async throws
    func restart(_ id: String) async throws
    /// Never removes the container's volumes and never forces.
    func removeContainer(_ id: String) async throws
    /// Never forces.
    func removeImage(_ id: String) async throws
    /// Never forces.
    func removeVolume(_ name: String) async throws
    func isTTY(containerID: String) async throws -> Bool
    /// Bytes Docker uses inside the VM: image layers, volumes, build cache and container writable layers.
    func diskUsage() async throws -> Int64
    func logs(containerID: String, tail: Int, tty: Bool) -> AsyncThrowingStream<LogLine, Error>
    func events() -> AsyncThrowingStream<DockerEvent, Error>
}

public final class DockerAPI: DockerEngine, @unchecked Sendable {
    private static let dfTTL: TimeInterval = 5

    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var apiVersion: String?
    private var dfCache: (at: Date, info: DFInfo)?

    private struct DFInfo { let volumeSizes: [String: Int64]; let totalBytes: Int64 }

    public convenience init(socketPath: String) {
        self.init(transport: UnixHTTPClient(socketPath: socketPath))
    }

    init(transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    // MARK: Negotiation

    public func negotiate() async throws {
        struct Version: Decodable { let ApiVersion: String }
        let res = try await transport.send(HTTPRequest(method: "GET", path: "/version"))
        let v = try decode(Version.self, from: res.body)
        lock.withLock { apiVersion = v.ApiVersion }
    }

    private func versioned(_ path: String) async throws -> String {
        if lock.withLock({ apiVersion }) == nil { try await negotiate() }
        return "/v\(lock.withLock { apiVersion } ?? "")\(path)"
    }

    /// Waits that legitimately take long: stopping a container (grace period), `/system/df` on big hosts.
    private static let slowTimeout: TimeInterval = 120

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:],
                                   timeout: TimeInterval? = nil) async throws -> T {
        let res = try await transport.send(HTTPRequest(method: "GET", path: try await versioned(path), query: query, timeout: timeout))
        return try decode(type, from: res.body)
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:]) async throws {
        _ = try await transport.send(HTTPRequest(method: method, path: try await versioned(path), query: query, timeout: Self.slowTimeout))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DockerError.decoding(String(describing: error)) }
    }

    // MARK: Reads

    public func containers() async throws -> [ContainerSummary] {
        struct DTO: Decodable {
            struct Port: Decodable { let PrivatePort: Int; let PublicPort: Int?; let `Type`: String }
            struct Mount: Decodable { let `Type`: String?; let Name: String? }
            let Id: String
            let Names: [String]?
            let Image: String
            let ImageID: String
            let State: String
            let Status: String
            let Ports: [Port]?
            let Labels: [String: String]?
            let Mounts: [Mount]?
            let Created: Double
        }
        let dtos = try await get([DTO].self, "/containers/json", query: ["all": "1"])
        return dtos.map { d in
            let firstName = d.Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            return ContainerSummary(
                id: d.Id,
                name: (firstName?.isEmpty == false ? firstName : nil) ?? String(d.Id.prefix(12)),
                image: d.Image,
                imageID: d.ImageID,
                state: ContainerState(rawValue: d.State) ?? .exited,
                status: d.Status,
                ports: (d.Ports ?? []).map { PortMapping(privatePort: $0.PrivatePort, publicPort: $0.PublicPort, type: $0.Type) },
                composeProject: d.Labels?["com.docker.compose.project"],
                composeService: d.Labels?["com.docker.compose.service"],
                volumeNames: (d.Mounts ?? []).filter { $0.Type == "volume" }.compactMap(\.Name),
                created: Date(timeIntervalSince1970: d.Created))
        }
    }

    public func images() async throws -> [ImageSummary] {
        struct DTO: Decodable { let Id: String; let RepoTags: [String]?; let Size: Int64; let Created: Double }
        let dtos = try await get([DTO].self, "/images/json")
        return dtos.map { d in
            ImageSummary(id: d.Id,
                         tags: (d.RepoTags ?? []).filter { $0 != "<none>:<none>" },
                         size: d.Size,
                         created: Date(timeIntervalSince1970: d.Created))
        }
    }

    public func volumes() async throws -> [VolumeSummary] {
        struct List: Decodable {
            struct V: Decodable { let Name: String; let Driver: String; let Mountpoint: String; let CreatedAt: String? }
            let Volumes: [V]?
        }
        let list = try await get(List.self, "/volumes")
        let sizes = try await volumeSizes()
        return (list.Volumes ?? []).map { v in
            VolumeSummary(name: v.Name, driver: v.Driver, mountpoint: v.Mountpoint,
                          size: sizes[v.Name], createdAt: v.CreatedAt.flatMap(Self.parseDate))
        }
    }

    private func volumeSizes() async throws -> [String: Int64] { try await systemDF().volumeSizes }

    public func diskUsage() async throws -> Int64 { try await systemDF().totalBytes }

    /// `/system/df`, cached briefly so a burst of events does not hammer the slow endpoint.
    /// Volume sizes of -1 (not computed) are left out.
    private func systemDF() async throws -> DFInfo {
        let fresh = lock.withLock { dfCache.flatMap { now().timeIntervalSince($0.at) < Self.dfTTL ? $0.info : nil } }
        if let fresh { return fresh }
        struct DF: Decodable {
            struct V: Decodable { struct U: Decodable { let Size: Int64 }; let Name: String; let UsageData: U? }
            struct C: Decodable { let SizeRw: Int64? }
            struct B: Decodable { let Size: Int64? }
            let LayersSize: Int64?
            let Volumes: [V]?
            let Containers: [C]?
            let BuildCache: [B]?
        }
        let df = try await get(DF.self, "/system/df", timeout: Self.slowTimeout)
        var sizes: [String: Int64] = [:]
        for v in df.Volumes ?? [] {
            if let s = v.UsageData?.Size, s >= 0 { sizes[v.Name] = s }
        }
        let total = (df.LayersSize ?? 0) + sizes.values.reduce(0, +)
            + (df.Containers ?? []).reduce(0) { $0 + max(0, $1.SizeRw ?? 0) }
            + (df.BuildCache ?? []).reduce(0) { $0 + max(0, $1.Size ?? 0) }
        let info = DFInfo(volumeSizes: sizes, totalBytes: total)
        lock.withLock { dfCache = (now(), info) }
        return info
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    public func isTTY(containerID: String) async throws -> Bool {
        struct Inspect: Decodable { struct Config: Decodable { let Tty: Bool }; let Config: Config }
        return try await get(Inspect.self, "/containers/\(containerID)/json").Config.Tty
    }

    // MARK: Mutations (never forced)

    public func start(_ id: String) async throws { try await call("POST", "/containers/\(id)/start") }
    public func stop(_ id: String) async throws { try await call("POST", "/containers/\(id)/stop") }
    public func restart(_ id: String) async throws { try await call("POST", "/containers/\(id)/restart") }

    public func removeContainer(_ id: String) async throws {
        try await call("DELETE", "/containers/\(id)", query: ["v": "0", "force": "0"])
    }

    public func removeImage(_ id: String) async throws {
        try await call("DELETE", "/images/\(id)", query: ["force": "0", "noprune": "0"])
    }

    public func removeVolume(_ name: String) async throws {
        try await call("DELETE", "/volumes/\(name)", query: ["force": "0"])
    }

    // MARK: Streams

    public func logs(containerID: String, tail: Int, tty: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = HTTPRequest(
                        method: "GET", path: try await self.versioned("/containers/\(containerID)/logs"),
                        query: ["stdout": "1", "stderr": "1", "follow": "1", "tail": String(tail), "timestamps": "0"])
                    var decoder = LogDecoder(tty: tty)
                    for try await chunk in self.transport.stream(request) {
                        for line in decoder.feed(chunk) { continuation.yield(line) }
                    }
                    for line in decoder.finish() { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func events() -> AsyncThrowingStream<DockerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = HTTPRequest(method: "GET", path: try await self.versioned("/events"))
                    var buffer = Data()
                    for try await chunk in self.transport.stream(request) {
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[..<nl]
                            buffer.removeSubrange(...nl)
                            if let event = Self.parseEvent(Data(line)) { continuation.yield(event) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseEvent(_ line: Data) -> DockerEvent? {
        struct Raw: Decodable {
            struct Actor: Decodable { let ID: String? }
            let `Type`: String?
            let Action: String?
            let Actor: Actor?
        }
        guard !line.isEmpty, let raw = try? JSONDecoder().decode(Raw.self, from: line) else { return nil }
        let id = raw.Actor?.ID ?? "", action = raw.Action ?? ""
        // Healthchecks and exec sessions emit these every few seconds; they never change what the lists show.
        let chatty = ["exec_", "health_status", "attach", "detach", "resize", "top"]
        if chatty.contains(where: { action.hasPrefix($0) }) { return .other }
        switch raw.Type {
        case "container": return .container(id: id, action: action)
        case "image": return .image(id: id, action: action)
        case "volume": return .volume(name: id, action: action)
        default: return .other
        }
    }
}
