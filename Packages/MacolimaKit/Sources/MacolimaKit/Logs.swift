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
