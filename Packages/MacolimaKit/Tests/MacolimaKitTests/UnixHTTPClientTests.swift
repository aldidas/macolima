import XCTest
@testable import MacolimaKit

final class UnixHTTPClientTests: XCTestCase {
    private func ok(_ body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    func test_send_parsesContentLengthBody() async throws {
        let server = try FakeUnixServer(response: ok(#"{"a":1}"#))
        let res = try await UnixHTTPClient(socketPath: server.path).send(HTTPRequest(method: "GET", path: "/x"))
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(String(decoding: res.body, as: UTF8.self), #"{"a":1}"#)
    }

    func test_send_decodesChunkedBody() async throws {
        let server = try FakeUnixServer(response:
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        let res = try await UnixHTTPClient(socketPath: server.path).send(HTTPRequest(method: "GET", path: "/x"))
        XCTAssertEqual(String(decoding: res.body, as: UTF8.self), "hello world")
    }

    func test_send_writesRequestLineHostAndQuery() async throws {
        let server = try FakeUnixServer(response: ok("[]"))
        _ = try await UnixHTTPClient(socketPath: server.path)
            .send(HTTPRequest(method: "GET", path: "/v1.45/containers/json", query: ["all": "1"]))
        let req = server.receivedRequest
        XCTAssertTrue(req.hasPrefix("GET /v1.45/containers/json?all=1 HTTP/1.1\r\n"), req)
        XCTAssertTrue(req.contains("\r\nHost: "), req)
    }

    func test_send_nonexistentPath_throwsSocketMissing() async {
        let client = UnixHTTPClient(socketPath: "/tmp/mc-does-not-exist.sock")
        do {
            _ = try await client.send(HTTPRequest(method: "GET", path: "/x"))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? DockerError, .socketMissing)
        }
    }

    func test_send_filePresentNoListener_throwsConnectionRefused() async throws {
        let path = try FakeUnixServer.makeDeadSocketFile()
        defer { unlink(path) }
        do {
            _ = try await UnixHTTPClient(socketPath: path).send(HTTPRequest(method: "GET", path: "/x"))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? DockerError, .connectionRefused)
        }
    }

    func test_stream_yieldsChunksIncrementallyThenFinishes() async throws {
        let server = try FakeUnixServer(script: [
            .send(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\none\r\n".utf8)),
            .waitForSignal,
            .send(Data("3\r\ntwo\r\n0\r\n\r\n".utf8)),
        ])
        var it = UnixHTTPClient(socketPath: server.path)
            .stream(HTTPRequest(method: "GET", path: "/events")).makeAsyncIterator()
        let first = try await it.next()
        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, "one")
        server.signal()
        let second = try await it.next()
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, "two")
        let end = try await it.next()
        XCTAssertNil(end)
    }

    func test_send_http404_surfacesStatusAndMessageFromJSON() async throws {
        let body = #"{"message":"No such container"}"#
        let server = try FakeUnixServer(response:
            "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        do {
            _ = try await UnixHTTPClient(socketPath: server.path).send(HTTPRequest(method: "DELETE", path: "/containers/x"))
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? DockerError, .http(status: 404, message: "No such container"))
        }
    }
}
