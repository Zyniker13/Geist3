/// A 1-based source position: line and column (column counts characters
/// from the start of the line).
public struct SourcePosition: Sendable, Hashable, Codable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

/// A source range: `start` is the first character, `end` is the position
/// just past the last character of the range.
public struct SourceSpan: Sendable, Hashable, Codable {
    public let start: SourcePosition
    public let end: SourcePosition

    public init(start: SourcePosition, end: SourcePosition) {
        self.start = start
        self.end = end
    }
}
