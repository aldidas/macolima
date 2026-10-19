import Foundation
import Darwin

public enum ShellError: Error, Equatable {
    case notFound(String)
    case failed(exe: String, code: Int32, stderr: String)
}

extension ShellError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let exe): return "\(exe) was not found. Is it installed?"
        case .failed(let exe, let code, let stderr): return stderr.isEmpty ? "\(exe) exited with code \(code)" : stderr
        }
    }
}

public enum Shell {
    /// GUI apps start with a minimal PATH: add Homebrew's and whatever the login shell would see.
    static let searchPath: [String] = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let login = loginShellPath() { dirs += login.split(separator: ":").map(String.init) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    private static func loginShellPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
    }

    public static func find(_ exe: String) -> URL? {
        if exe.contains("/") { return FileManager.default.isExecutableFile(atPath: exe) ? URL(fileURLWithPath: exe) : nil }
        for dir in searchPath {
            let path = dir + "/" + exe
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Runs `exe` and returns its stdout; a non-zero exit throws `ShellError.failed` with stderr.
    public static func run(_ exe: String, _ args: [String]) async throws -> String {
        guard let url = find(exe) else { throw ShellError.notFound(exe) }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = url
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPath.joined(separator: ":")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(throwing: error) }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: outData, as: UTF8.self))
                } else {
                    let stderr = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: ShellError.failed(exe: exe, code: p.terminationStatus, stderr: stderr))
                }
            }
        }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}

public struct SocketInfo: Equatable, Sendable {
    public let path: String
    public let profile: String

    public init(path: String, profile: String) {
        self.path = path
        self.profile = profile
    }
}

public enum SocketLocator {
    /// Socket of the active Docker context; `~/.colima/default/docker.sock` when that cannot be determined.
    public static func resolve(run: (String, [String]) async throws -> String = Shell.run,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> SocketInfo {
        let fallback = SocketInfo(path: home.appendingPathComponent(".colima/default/docker.sock").path, profile: "default")
        guard let out = try? await run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]) else { return fallback }
        let endpoint = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.hasPrefix("unix://") else { return fallback }
        let path = String(endpoint.dropFirst("unix://".count))
        guard !path.isEmpty else { return fallback }
        return SocketInfo(path: path, profile: profile(fromSocketPath: path))
    }

    /// `…/.colima/<profile>/docker.sock` → `<profile>`; anything else → `default`.
    static func profile(fromSocketPath path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: ".colima"), i + 2 < parts.count, parts.last == "docker.sock" { return parts[i + 1] }
        return "default"
    }
}

public struct ColimaInfo: Equatable, Sendable {
    public let cpus: Int
    public let memoryBytes: Int64
    public let diskMaxBytes: Int64
    public let runtime: String

    public init(cpus: Int, memoryBytes: Int64, diskMaxBytes: Int64, runtime: String) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskMaxBytes = diskMaxBytes
        self.runtime = runtime
    }
}

public enum ColimaStatus: Equatable, Sendable {
    case stopped
    case running(ColimaInfo)
}

public struct DiskUsage: Equatable, Sendable {
    public let allocatedBytes: Int64
    public let maxBytes: Int64?

    public init(allocatedBytes: Int64, maxBytes: Int64?) {
        self.allocatedBytes = allocatedBytes
        self.maxBytes = maxBytes
    }
}

public struct ColimaService: Sendable {
    public typealias Runner = @Sendable (String, [String]) async throws -> String

    private let profile: String
    private let home: URL
    private let run: Runner

    public init(profile: String,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                run: @escaping Runner = { try await Shell.run($0, $1) }) {
        self.profile = profile
        self.home = home
        self.run = run
    }

    public func status() async -> ColimaStatus {
        struct Raw: Decodable { let cpu: Int; let memory: Int64; let disk: Int64; let runtime: String }
        guard let out = try? await run("colima", ["status", "--json", "-p", profile]),
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(out.utf8)) else { return .stopped }
        return .running(ColimaInfo(cpus: raw.cpu, memoryBytes: raw.memory, diskMaxBytes: raw.disk, runtime: raw.runtime))
    }

    public func start() async throws { _ = try await run("colima", ["start", "-p", profile]) }
    public func stop() async throws { _ = try await run("colima", ["stop", "-p", profile]) }

    /// Lima's name for the profile's VM: `colima` for the default profile, `colima-<profile>` otherwise.
    private var instance: String { profile == "default" ? "colima" : "colima-\(profile)" }

    /// Blocks actually allocated on the Mac (`st_blocks * 512`, not the sparse apparent size) by the VM's
    /// disk images: the instance's boot disk and the data disk that holds Docker's data.
    public func hostDisk(maxBytes: Int64? = nil) -> DiskUsage? {
        let lima = home.appendingPathComponent(".colima/_lima")
        let candidates = [
            lima.appendingPathComponent("\(instance)/diffdisk"),
            lima.appendingPathComponent("\(instance)/disk"),
            lima.appendingPathComponent("_disks/\(instance)/datadisk"),
        ]
        var total: Int64 = 0
        var found = false
        for url in candidates {
            var st = stat()
            guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            total += Int64(st.st_blocks) * 512
            found = true
        }
        return found ? DiskUsage(allocatedBytes: total, maxBytes: maxBytes) : nil
    }
}
