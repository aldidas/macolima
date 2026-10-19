import Foundation
@testable import MacolimaKit

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

/// In-memory `HTTPTransport` that records requests and serves canned responses.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    var handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    var streamChunks: [Data] = []

    init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        return try handler(request)
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _requests.append(request) }
        let chunks = streamChunks
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }

    /// Serves the fixtures by path suffix; everything else answers 204.
    static func standard() -> FakeTransport {
        FakeTransport { req in
            func ok(_ name: String) -> HTTPResponse { HTTPResponse(status: 200, headers: [:], body: Fixture.data(name)) }
            if req.path.hasSuffix("/version") { return ok("version") }
            if req.path.hasSuffix("/containers/json") { return ok("containers") }
            if req.path.hasSuffix("/images/json") { return ok("images") }
            if req.path.hasSuffix("/system/df") { return ok("system_df") }
            if req.path.hasSuffix("/volumes") { return ok("volumes") }
            return HTTPResponse(status: 204, headers: [:], body: Data())
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ s: TimeInterval) { lock.lock(); date += s; lock.unlock() }
}
