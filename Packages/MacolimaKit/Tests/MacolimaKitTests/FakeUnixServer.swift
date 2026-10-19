import Foundation
import Darwin

/// Tiny single-connection unix-socket server for tests. Binds a temp path, plays a
/// script of steps against the first client, and records the request it received.
final class FakeUnixServer: @unchecked Sendable {
    enum Step {
        case send(Data)
        case waitForSignal
    }

    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var _request = Data()
    private let signalSemaphore = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    init(script: [Step]) throws {
        // sun_path is ~104 bytes; keep the path short.
        path = "/tmp/mc-\(UUID().uuidString.prefix(8)).sock"
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        try Self.bind(fd: listenFD, path: path)
        guard listen(listenFD, 1) == 0 else { throw POSIXError(.EIO) }
        let fd = listenFD
        Thread.detachNewThread { [self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { done.signal(); return }
            var buf = [UInt8](repeating: 0, count: 4096)
            var req = Data()
            while !req.suffix(4).elementsEqual("\r\n\r\n".utf8) {
                let n = read(conn, &buf, buf.count)
                if n <= 0 { break }
                req.append(contentsOf: buf[0..<n])
            }
            lock.lock(); _request = req; lock.unlock()
            for step in script {
                switch step {
                case .send(let data):
                    data.withUnsafeBytes { _ = write(conn, $0.baseAddress, data.count) }
                case .waitForSignal:
                    _ = signalSemaphore.wait(timeout: .now() + 5)
                }
            }
            close(conn)
            done.signal()
        }
    }

    /// Convenience: reply with `response` and close.
    convenience init(response: String) throws {
        try self.init(script: [.send(Data(response.utf8))])
    }

    var receivedRequest: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: _request, as: UTF8.self)
    }

    func signal() { signalSemaphore.signal() }

    func stop() {
        close(listenFD)
        unlink(path)
    }

    deinit { stop() }

    /// Creates a socket file that nothing listens on (connect → ECONNREFUSED).
    static func makeDeadSocketFile() throws -> String {
        let path = "/tmp/mc-dead-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try bind(fd: fd, path: path)
        close(fd)
        return path
    }

    static func bind(fd: Int32, path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
