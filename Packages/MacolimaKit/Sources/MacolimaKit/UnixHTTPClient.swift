import Foundation
import Darwin

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data?
    /// Seconds to wait for the engine to answer; `nil` = the transport's default. Ignored for streams.
    public let timeout: TimeInterval?

    public init(method: String, path: String, query: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data
}

public enum DockerError: Error, Equatable {
    case socketMissing
    case connectionRefused
    /// The engine accepted the connection but did not answer in time (a wedged daemon or VM).
    case timedOut
    case http(status: Int, message: String)
    case decoding(String)
}

/// Anything that can carry Docker Engine requests; `UnixHTTPClient` is the production conformer.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

/// HTTP/1.1 over a unix domain socket, one connection per request (`Connection: close`).
public struct UnixHTTPClient: HTTPTransport {
    let socketPath: String
    let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var body = Data()
                do {
                    let head = try self.perform(request, fd: nil) { body.append($0) }
                    cont.resume(returning: HTTPResponse(status: head.status, headers: head.headers, body: body))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let box = FDBox()
            continuation.onTermination = { _ in box.shutdown() }
            Thread.detachNewThread {
                do {
                    _ = try self.perform(request, fd: box) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking exchange

    private struct Head { let status: Int; let headers: [String: String] }

    /// Connects, sends the request and feeds decoded body bytes to `onBody` as they arrive.
    /// Responses with status >= 400 are collected and thrown as `DockerError.http`.
    private func perform(_ request: HTTPRequest, fd box: FDBox?, onBody: (Data) -> Void) throws -> Head {
        let fd = try connect()
        box?.set(fd)
        defer { box?.clear(); Darwin.close(fd) }
        // Streams (events, logs) are idle for long stretches by design; one-shot requests must not hang forever.
        if box == nil { Self.setTimeout(fd, request.timeout ?? timeout) }

        try writeAll(fd, Self.serialize(request))

        var buffer = Data()
        var head: Head?
        var chunked: ChunkedDecoder?
        var errorBody = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        func handle(_ bytes: Data) {
            guard let head else { return }
            let decoded = chunked?.feed(bytes) ?? bytes
            if head.status >= 400 { errorBody.append(decoded) } else if !decoded.isEmpty { onBody(decoded) }
        }

        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                if box?.isShutdown == true { break }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw DockerError.timedOut }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            if head == nil {
                buffer.append(contentsOf: chunk[0..<n])
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
                head = try Self.parseHead(buffer[..<range.lowerBound])
                if head?.headers["transfer-encoding"]?.lowercased().contains("chunked") == true { chunked = ChunkedDecoder() }
                let rest = Data(buffer[range.upperBound...])
                buffer = Data()
                if !rest.isEmpty { handle(rest) }
            } else {
                handle(Data(chunk[0..<n]))
            }
        }
        guard let head else { throw DockerError.decoding("connection closed before response headers") }
        if head.status >= 400 {
            throw DockerError.http(status: head.status, message: Self.errorMessage(from: errorBody))
        }
        return head
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(fd)
            switch err {
            case ENOENT: throw DockerError.socketMissing
            case ECONNREFUSED: throw DockerError.connectionRefused
            default: throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
        }
        return fd
    }

    private static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw DockerError.timedOut }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }

    // MARK: - Wire format

    static func serialize(_ request: HTTPRequest) -> Data {
        var target = request.path
        if !request.query.isEmpty {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let pairs = request.query.keys.sorted().map { key -> String in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = request.query[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? request.query[key]!
                return "\(k)=\(v)"
            }
            target += "?" + pairs.joined(separator: "&")
        }
        var text = "\(request.method) \(target) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nAccept: */*\r\n"
        if let body = request.body {
            text += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body = request.body { data.append(body) }
        return data
    }

    private static func parseHead(_ raw: Data) throws -> Head {
        let text = String(decoding: raw, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw DockerError.decoding("bad status line: \(lines.first ?? "")")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(status: status, headers: headers)
    }

    private static func errorMessage(from body: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let m = obj["message"] as? String {
            return m
        }
        return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds the connected fd so a stream's termination can unblock its reader.
private final class FDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var isShutdown = false

    func set(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        self.fd = fd
        if isShutdown { Darwin.shutdown(fd, SHUT_RDWR) }
    }
    func clear() { lock.lock(); fd = -1; lock.unlock() }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        isShutdown = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }
}

/// Incremental `Transfer-Encoding: chunked` decoder.
struct ChunkedDecoder {
    private enum State { case size, data(Int), dataEnd, done }
    private var state = State.size
    private var buffer = Data()

    mutating func feed(_ bytes: Data) -> Data {
        buffer.append(bytes)
        var out = Data()
        loop: while true {
            switch state {
            case .size:
                guard let r = buffer.range(of: Data("\r\n".utf8)) else { break loop }
                let line = String(decoding: buffer[..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<r.upperBound)
                let hex = line.split(separator: ";").first.map(String.init) ?? ""
                let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
                state = size == 0 ? .done : .data(size)
            case .data(let remaining):
                if buffer.isEmpty { break loop }
                let take = min(remaining, buffer.count)
                out.append(buffer.prefix(take))
                buffer.removeFirst(take)
                state = remaining - take == 0 ? .dataEnd : .data(remaining - take)
            case .dataEnd:
                if buffer.count < 2 { break loop }
                buffer.removeFirst(2)
                state = .size
            case .done:
                buffer.removeAll()
                break loop
            }
        }
        return out
    }
}
