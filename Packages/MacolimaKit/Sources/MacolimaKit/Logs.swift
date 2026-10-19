import Foundation

public struct LogLine: Hashable, Sendable {
    public enum Stream: Sendable { case stdout, stderr }

    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Turns the engine's log byte stream into lines. Multiplexed streams carry 8-byte frame headers
/// (type byte, 3 zero bytes, big-endian length); TTY streams are raw. Partial frames and partial
/// lines are buffered across `feed` calls.
public struct LogDecoder {
    private var raw: Bool
    private var pending: [UInt8] = []
    private var partial: [LogLine.Stream: [UInt8]] = [:]

    public init(tty: Bool) { raw = tty }

    public mutating func feed(_ data: Data) -> [LogLine] {
        pending.append(contentsOf: data)
        var lines: [LogLine] = []
        while true {
            if raw {
                lines += extractLines(.stdout, pending)
                pending.removeAll()
                return lines
            }
            guard pending.count >= 8 else { return lines }
            // Not a frame header (wrong TTY guess, or a proxy in between): treat the stream as raw text.
            guard pending[0] <= 2, pending[1] == 0, pending[2] == 0, pending[3] == 0 else {
                raw = true
                continue
            }
            let length = pending[4..<8].reduce(0) { $0 << 8 | Int($1) }
            guard pending.count >= 8 + length else { return lines }
            let stream: LogLine.Stream = pending[0] == 2 ? .stderr : .stdout
            let payload = Array(pending[8..<(8 + length)])
            pending.removeFirst(8 + length)
            lines += extractLines(stream, payload)
        }
    }

    /// Emits whatever is left as unterminated final lines once the stream has ended.
    public mutating func finish() -> [LogLine] {
        var lines: [LogLine] = []
        for stream in [LogLine.Stream.stdout, .stderr] {
            if let rest = partial[stream], !rest.isEmpty { lines.append(Self.line(stream, rest)) }
        }
        partial.removeAll()
        pending.removeAll()
        return lines
    }

    private mutating func extractLines(_ stream: LogLine.Stream, _ bytes: [UInt8]) -> [LogLine] {
        var buffer = partial[stream] ?? []
        buffer.append(contentsOf: bytes)
        var lines: [LogLine] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Self.line(stream, Array(buffer[..<nl])))
            buffer.removeSubrange(...nl)
        }
        partial[stream] = buffer
        return lines
    }

    private static func line(_ stream: LogLine.Stream, _ bytes: [UInt8]) -> LogLine {
        var bytes = bytes
        if bytes.last == 0x0D { bytes.removeLast() }
        return LogLine(stream: stream, text: String(decoding: bytes, as: UTF8.self))
    }
}

/// Bounded in-memory tail: keeps the newest `capacity` lines.
public struct LogBuffer {
    private let capacity: Int
    public private(set) var lines: [LogLine] = []

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ new: [LogLine]) {
        lines.append(contentsOf: new)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
}
