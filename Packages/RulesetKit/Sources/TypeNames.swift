import CardExpr

// MARK: - Type-name parsing

/// Parses the DSL type names that appear in ruleset JSON (option types,
/// var types, def signatures) into `ExprType` values.
public enum RulesetTypeNames {
    /// The zero span used for errors found outside expression text; the
    /// loader replaces these with JSON-pointer context when reporting.
    public static let zeroSpan = SourceSpan(
        start: SourcePosition(line: 0, column: 0),
        end: SourcePosition(line: 0, column: 0)
    )

    private static let scalars: [String: ExprType] = [
        "int": .int, "bool": .bool, "string": .string, "suit": .suit,
        "rank": .rank, "card": .card, "seat": .seat, "team": .team,
        "phase": .phase, "any": .any,
    ]

    /// Parses a type name such as `int`, `suit?`, `list<card>`, or a
    /// registered record name.
    public static func parse(
        _ text: String,
        records: [String: RecordType] = [:]
    ) throws -> ExprType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") {
            return .optional(try parse(String(trimmed.dropLast()), records: records))
        }
        if trimmed.hasPrefix("list<"), trimmed.hasSuffix(">") {
            return .list(try parse(String(trimmed.dropFirst(5).dropLast()), records: records))
        }
        if let scalar = scalars[trimmed] { return scalar }
        if let record = records[trimmed] ?? canonicalRecords[trimmed] {
            return .record(record)
        }
        throw TypeError(span: zeroSpan, message: "unknown type '\(trimmed)'")
    }

    /// Parses a def signature such as `isLeft(c: card) -> bool` into its
    /// name, parameter names, parameter types, and result type. The body
    /// is parsed separately from its own expression text.
    public static func parseDefSignature(
        _ text: String,
        records: [String: RecordType] = [:]
    ) throws -> DefHeader {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let arrow = trimmed.range(of: "->") else {
            throw TypeError(
                span: zeroSpan,
                message: "def signature '\(text)' is missing '-> ret'"
            )
        }
        let head = String(trimmed[trimmed.startIndex..<arrow.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try parse(String(trimmed[arrow.upperBound...]), records: records)
        guard let open = head.firstIndex(of: "(") else {
            guard !head.isEmpty else {
                throw TypeError(
                    span: zeroSpan,
                    message: "def signature '\(text)' is missing a name"
                )
            }
            return DefHeader(name: head, params: [], types: [], result: result)
        }
        let name = String(head[head.startIndex..<open])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TypeError(
                span: zeroSpan,
                message: "def signature '\(text)' is missing a name"
            )
        }
        guard head.hasSuffix(")") else {
            throw TypeError(
                span: zeroSpan,
                message: "def signature '\(text)' is missing ')'"
            )
        }
        let parameterText = head[head.index(after: open)..<head.index(before: head.endIndex)]
        let (params, types) = try parseParams(parameterText, signature: text, records: records)
        return DefHeader(name: name, params: params, types: types, result: result)
    }

    /// Parses the `name: type` pieces between the parentheses of a def
    /// signature into parallel name and type lists.
    private static func parseParams(
        _ parameterText: Substring,
        signature: String,
        records: [String: RecordType]
    ) throws -> ([String], [ExprType]) {
        var params: [String] = []
        var types: [ExprType] = []
        for piece in parameterText.split(separator: ",") {
            let part = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = part.firstIndex(of: ":") else {
                throw TypeError(
                    span: zeroSpan,
                    message: "def parameter '\(part)' is missing ': type'"
                )
            }
            let parameterName = String(part[part.startIndex..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parameterName.isEmpty else {
                throw TypeError(
                    span: zeroSpan,
                    message: "def parameter is missing a name in '\(signature)'"
                )
            }
            params.append(parameterName)
            types.append(try parse(String(part[part.index(after: colon)...]), records: records))
        }
        return (params, types)
    }
}
