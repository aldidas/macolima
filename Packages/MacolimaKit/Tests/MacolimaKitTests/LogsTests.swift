import XCTest
@testable import MacolimaKit

final class LogsTests: XCTestCase {
    /// Docker's multiplexed frame: type byte, 3 zero bytes, big-endian length, payload.
    static func frame(_ type: UInt8, _ text: String) -> Data {
        let payload = Data(text.utf8)
        var d = Data([type, 0, 0, 0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d.append(contentsOf: $0) }
        return d + payload
    }

    func test_multiplexed_stdoutAndStderrFrames() {
        var dec = LogDecoder(tty: false)
        let lines = dec.feed(Self.frame(1, "out line\n") + Self.frame(2, "err line\n"))
        XCTAssertEqual(lines, [LogLine(stream: .stdout, text: "out line"), LogLine(stream: .stderr, text: "err line")])
    }

    func test_multiplexed_frameSplitAcrossTwoFeeds() {
        var dec = LogDecoder(tty: false)
        let data = Self.frame(1, "hello world\n")
        XCTAssertEqual(dec.feed(data.prefix(3)), [])           // inside the header
        XCTAssertEqual(dec.feed(data[3..<12]), [])             // header done, payload partial
        XCTAssertEqual(dec.feed(data.dropFirst(12)), [LogLine(stream: .stdout, text: "hello world")])
    }

    func test_tty_rawLinesNoFraming() {
        var dec = LogDecoder(tty: true)
        XCTAssertEqual(dec.feed(Data("one\r\ntwo\n".utf8)), [LogLine(stream: .stdout, text: "one"), LogLine(stream: .stdout, text: "two")])
    }

    func test_lineSplitAcrossFeedsIsJoined() {
        var tty = LogDecoder(tty: true)
        XCTAssertEqual(tty.feed(Data("par".utf8)), [])
        XCTAssertEqual(tty.feed(Data("tial\n".utf8)), [LogLine(stream: .stdout, text: "partial")])

        var mux = LogDecoder(tty: false)
        XCTAssertEqual(mux.feed(Self.frame(1, "wor")), [])
        XCTAssertEqual(mux.feed(Self.frame(2, "x\n")), [LogLine(stream: .stderr, text: "x")])   // streams buffer separately
        XCTAssertEqual(mux.feed(Self.frame(1, "ld\n")), [LogLine(stream: .stdout, text: "world")])
    }

    func test_multibyteCharacterSplitAcrossFeedsSurvives() {
        var dec = LogDecoder(tty: true)
        let bytes = Array("héllo\n".utf8)   // é is two bytes
        XCTAssertEqual(dec.feed(Data(bytes[0..<2])), [])
        XCTAssertEqual(dec.feed(Data(bytes[2...])), [LogLine(stream: .stdout, text: "héllo")])
    }

    func test_finish_flushesUnterminatedLine() {
        var dec = LogDecoder(tty: true)
        _ = dec.feed(Data("no newline".utf8))
        XCTAssertEqual(dec.finish(), [LogLine(stream: .stdout, text: "no newline")])
        XCTAssertEqual(dec.finish(), [])
    }

    func test_buffer_dropsOldestBeyondCapacity() {
        var buf = LogBuffer(capacity: 3)
        buf.append((1...2).map { LogLine(stream: .stdout, text: "\($0)") })
        buf.append((3...5).map { LogLine(stream: .stdout, text: "\($0)") })
        XCTAssertEqual(buf.lines.map(\.text), ["3", "4", "5"])
    }

    func test_dockerAPI_logs_requestsFollowTail_andDecodesStream() async throws {
        let t = FakeTransport.standard()
        let framed = Self.frame(1, "a\nb") + Self.frame(2, "c\n")
        t.streamChunks = [framed.prefix(10), framed.dropFirst(10)]
        var out: [LogLine] = []
        for try await line in DockerAPI(transport: t).logs(containerID: "c1", tail: 200, tty: false) { out.append(line) }
        // stdout's unterminated "b" is held back until the stream ends
        XCTAssertEqual(out, [LogLine(stream: .stdout, text: "a"), LogLine(stream: .stderr, text: "c"), LogLine(stream: .stdout, text: "b")])
        let req = t.requests.last
        XCTAssertEqual(req?.path, "/v1.47/containers/c1/logs")
        XCTAssertEqual(req?.query, ["stdout": "1", "stderr": "1", "follow": "1", "tail": "200", "timestamps": "0"])
    }

    func test_dockerAPI_logs_tty_decodesRawStream() async throws {
        let t = FakeTransport.standard()
        t.streamChunks = [Data("x\ny".utf8), Data("z\n".utf8)]
        var out: [String] = []
        for try await line in DockerAPI(transport: t).logs(containerID: "c1", tail: 10, tty: true) { out.append(line.text) }
        XCTAssertEqual(out, ["x", "yz"])
    }
}

extension LogsTests {
    func test_multiplexed_invalidHeaderFallsBackToRaw() {
        var dec = LogDecoder(tty: false)   // caller guessed wrong: this is plain text
        XCTAssertEqual(dec.feed(Data("plain text output here\n".utf8)), [LogLine(stream: .stdout, text: "plain text output here")])
    }
}
