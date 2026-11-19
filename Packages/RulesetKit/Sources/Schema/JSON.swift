// JSON tree used by the ruleset schema layer.
//
// Why not [String: Any] or Foundation Codable end to end: the loader must be
// lossless — decode → encode → decode identical in canonical form (P2.5) — and
// must preserve object key order (§5.1 wants schema key order on output; the
// validator warns on order) and the int/decimal distinction ("1" vs "1.0").
// This file is the single owned representation; everything else in Schema/
// reads and writes it through `JSONCodable`.

import Foundation

/// A parse/shape failure of a ruleset or overlay document.
public enum SchemaError: Error, Equatable, Sendable {
    /// Syntax error in the JSON text (or duplicate object key).
    case parse(String)
    /// A value that must be an object was something else.
    case notObject(path: String)
    /// A required key is absent.
    case missingKey(String, path: String)
    /// A key's value has the wrong JSON shape for its schema slot.
    case wrongType(expected: String, path: String)
    /// The `format` marker does not match the document kind.
    case formatMismatch(expected: String, actual: String)
}

/// An ordered key/value pair inside a JSON object. Order is preserved from the
/// source document so encode output and diffs stay faithful.
public struct JSONField: Equatable, Sendable {
    public var key: String
    public var value: JSON

    public init(key: String, value: JSON) {
        self.key = key
        self.value = value
    }
}

/// Lossless JSON value tree. Objects keep source key order; numbers keep the
/// literal distinction between integer and decimal forms. Non-integer numbers
/// are stored as exact decimal literals (no floating point per CONVENTIONS
/// §5.4 — canonicalization below is pure string/integer arithmetic).
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case decimal(String)
    case string(String)
    case array([JSON])
    case object([JSONField])

    // MARK: Convenience constructors and lookups

    public static func object(_ pairs: [(String, JSON)]) -> JSON {
        .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }

    /// Object field lookup by key (first match; parser forbids duplicates).
    public subscript(key: String) -> JSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first(where: { $0.key == key })?.value
    }

    /// All fields if this value is an object.
    public var fields: [JSONField]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    public var intValue: Int? {
        guard case .int(let i) = self else { return nil }
        return i
    }

    public var arrayValue: [JSON]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: Canonical form

    /// Recursively sorted object keys. Two documents that carry the same data
    /// in different key orders compare equal in canonical form.
    public func canonicallySorted() -> JSON {
        switch self {
        case .object(let fields):
            return .object(
                fields
                    .map { JSONField(key: $0.key, value: $0.value.canonicallySorted()) }
                    .sorted { $0.key < $1.key })
        case .array(let items):
            return .array(items.map { $0.canonicallySorted() })
        default:
            return self
        }
    }

    /// Canonical form with numbers normalized: integral decimals become ints
    /// (1.0 and 1 are the same number), other decimals collapse to a canonical
    /// literal. This is the form P2.5's round-trip equality and P2.6's hash
    /// input are defined on.
    public func normalizedForCompare() -> JSON {
        switch self {
        case .decimal(let literal):
            return JSON.canonicalDecimal(literal)
        case .object(let fields):
            return .object(
                fields
                    .map { JSONField(key: $0.key, value: $0.value.normalizedForCompare()) }
                    .sorted { $0.key < $1.key })
        case .array(let items):
            return .array(items.map { $0.normalizedForCompare() })
        default:
            return self
        }
    }

    /// Canonical text: sorted keys, normalized numbers, compact spacing.
    public func canonicalString() -> String {
        encode(indent: nil)
    }

    /// Pretty text with the repository's two-space indent style.
    public func prettyString() -> String {
        encode(indent: 0)
    }

    func encode(indent: Int?) -> String {
        var out = ""
        write(to: &out, indent: indent, depth: 0)
        return out
    }

    private func write(to out: inout String, indent: Int?, depth: Int) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .decimal(let literal):
            out += literal
        case .string(let s):
            JSON.writeEscaped(s, to: &out)
        case .array(let items):
            writeArray(items, to: &out, indent: indent, depth: depth)
        case .object(let fields):
            writeObject(fields, to: &out, indent: indent, depth: depth)
        }
    }

    private func writeArray(_ items: [JSON], to out: inout String, indent: Int?, depth: Int) {
        if items.isEmpty {
            out += "[]"
            return
        }
        out += "["
        for (index, item) in items.enumerated() {
            if index > 0 { out += "," }
            JSON.appendNewlineIfNeeded(to: &out, indent: indent, depth: depth + 1)
            item.write(to: &out, indent: indent, depth: depth + 1)
        }
        JSON.appendNewlineIfNeeded(to: &out, indent: indent, depth: depth)
        out += "]"
    }

    private func writeObject(_ fields: [JSONField], to out: inout String, indent: Int?, depth: Int) {
        if fields.isEmpty {
            out += "{}"
            return
        }
        out += "{"
        for (index, field) in fields.enumerated() {
            if index > 0 { out += "," }
            JSON.appendNewlineIfNeeded(to: &out, indent: indent, depth: depth + 1)
            JSON.writeEscaped(field.key, to: &out)
            out += ": "
            field.value.write(to: &out, indent: indent, depth: depth + 1)
        }
        JSON.appendNewlineIfNeeded(to: &out, indent: indent, depth: depth)
        out += "}"
    }

    private static func appendNewlineIfNeeded(to out: inout String, indent: Int?, depth: Int) {
        guard let indent else { return }
        out += "\n"
        out += String(repeating: " ", count: indent * depth)
    }

    /// Expands a JSON decimal literal to its canonical form: integral values
    /// (0.0, 1e2, -3.00) become `.int`; other decimals become a canonical
    /// literal without redundant zeros. Pure string/integer arithmetic —
    /// deterministic per CONVENTIONS §5.4.
    static func canonicalDecimal(_ literal: String) -> JSON {
        var text = Substring(literal)
        var negative = false
        if text.first == "-" {
            negative = true
            text = text.dropFirst()
        }
        // Split at exponent, if any. Literals always come from the parser,
        // which bounds the exponent; unparseable ones pass through verbatim.
        var exponent = 0
        if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let exponentText = text[text.index(after: eIndex)...]
            exponent = Int(exponentText) ?? 0
            text = text[..<eIndex]
        }
        // Split mantissa at the decimal point.
        let pointIndex = text.firstIndex(of: ".") ?? text.endIndex
        let intDigits = text[..<pointIndex]
        let fracDigits = text[(pointIndex < text.endIndex ? text.index(after: pointIndex) : text.endIndex)...]
        let digits = Array(intDigits) + Array(fracDigits)
        // Decimal point position relative to the start of `digits`.
        var pointPosition = intDigits.count + exponent
        // Strip leading zeros: each removed digit also shifts the point left.
        var lead = 0
        while lead < digits.count - 1, digits[lead] == "0" {
            lead += 1
            pointPosition -= 1
        }
        // Strip trailing zeros (fraction only — a trailing zero left of the
        // point scales the value).
        var end = digits.count
        while end > pointPosition + 1, end > lead + 1, digits[end - 1] == "0" {
            end -= 1
        }
        let kept = digits[lead..<end]
        let allZero = kept.allSatisfy { $0 == "0" }
        if allZero { return .int(0) }
        let digitsText = String(kept)
        if pointPosition >= digitsText.count {
            // Integral: append missing zeros; keep as int when it fits Int64.
            let valueText = digitsText + String(repeating: "0", count: pointPosition - digitsText.count)
            if let value = Int(valueText) {
                return .int(negative ? -value : value)
            }
            return .decimal((negative ? "-" : "") + valueText)
        }
        if pointPosition <= 0 {
            let frac = String(repeating: "0", count: -pointPosition) + digitsText
            return .decimal((negative ? "-" : "") + "0." + frac)
        }
        let split = digitsText.index(digitsText.startIndex, offsetBy: pointPosition)
        let intPart = String(digitsText[..<split])
        let fracPart = String(digitsText[split...])
        return .decimal((negative ? "-" : "") + intPart + "." + fracPart)
    }

    private static func writeEscaped(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u"
                    out += String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Parser

/// Strict RFC 8259 parser with source-order object fields and int/double
/// preservation. Rejects duplicate keys, control characters in strings,
/// leading zeros, and numbers that overflow Int without a decimal point.
public enum JSONParser {
    /// Maximum nesting depth; rulesets are shallow, this only bounds hostile input.
    static let maxDepth = 128

    public static func parse(_ data: Data) throws(SchemaError) -> JSON {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        try parser.skipWhitespace()
        guard parser.atEnd else {
            throw SchemaError.parse("unexpected trailing content at byte \(parser.index)")
        }
        return value
    }

    public static func parse(_ text: String) throws(SchemaError) -> JSON {
        try parse(Data(text.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var atEnd: Bool { index >= bytes.count }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        func describePosition() -> String {
            "byte \(index)"
        }

        mutating func skipWhitespace() throws(SchemaError) {
            while let b = current {
                switch b {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        mutating func parseValue(depth: Int) throws(SchemaError) -> JSON {
            if depth > JSONParser.maxDepth {
                throw SchemaError.parse("nesting too deep at \(describePosition())")
            }
            try skipWhitespace()
            guard let b = current else {
                throw SchemaError.parse("unexpected end of input at \(describePosition())")
            }
            switch b {
            case UInt8(ascii: "{"):
                return try parseObject(depth: depth)
            case UInt8(ascii: "["):
                return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumber()
            default:
                throw SchemaError.parse("unexpected character at \(describePosition())")
            }
        }

        mutating func expectLiteral(_ literal: String) throws(SchemaError) {
            for expected in literal.utf8 {
                guard current == expected else {
                    throw SchemaError.parse("bad literal at \(describePosition())")
                }
                index += 1
            }
        }

        mutating func parseObject(depth: Int) throws(SchemaError) -> JSON {
            index += 1  // consume {
            var fields: [JSONField] = []
            var seen: Set<String> = []
            try skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return .object(fields)
            }
            while true {
                try skipWhitespace()
                guard current == UInt8(ascii: "\"") else {
                    throw SchemaError.parse("expected object key at \(describePosition())")
                }
                let key = try parseString()
                guard !seen.contains(key) else {
                    throw SchemaError.parse("duplicate object key \"\(key)\" at \(describePosition())")
                }
                seen.insert(key)
                try skipWhitespace()
                guard current == UInt8(ascii: ":") else {
                    throw SchemaError.parse("expected ':' at \(describePosition())")
                }
                index += 1
                let value = try parseValue(depth: depth + 1)
                fields.append(JSONField(key: key, value: value))
                try skipWhitespace()
                switch current {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return .object(fields)
                default:
                    throw SchemaError.parse("expected ',' or '}' at \(describePosition())")
                }
            }
        }

        mutating func parseArray(depth: Int) throws(SchemaError) -> JSON {
            index += 1  // consume [
            var items: [JSON] = []
            try skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                let value = try parseValue(depth: depth + 1)
                items.append(value)
                try skipWhitespace()
                switch current {
                case UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return .array(items)
                default:
                    throw SchemaError.parse("expected ',' or ']' at \(describePosition())")
                }
            }
        }

        mutating func parseString() throws(SchemaError) -> String {
            index += 1  // consume opening quote
            var units: [UInt8] = []
            while true {
                guard let b = current else {
                    throw SchemaError.parse("unterminated string at \(describePosition())")
                }
                if b == UInt8(ascii: "\"") {
                    index += 1
                    guard let text = String(bytes: units, encoding: .utf8) else {
                        throw SchemaError.parse("invalid UTF-8 in string at \(describePosition())")
                    }
                    return text
                }
                if b == UInt8(ascii: "\\") {
                    let scalar = try parseEscape()
                    appendUTF8(scalar, to: &units)
                    continue
                }
                if b < 0x20 {
                    throw SchemaError.parse("control character in string at \(describePosition())")
                }
                units.append(b)
                index += 1
            }
        }

        /// Short-form escapes: the character after the backslash, mapped to
        /// its code point.
        private static let shortEscapes: [UInt8: UInt32] = [
            UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "/"): 0x2F,
            UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): 0x0A,
            UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
        ]

        /// Decodes an escape sequence whose backslash is `current`; consumes
        /// the backslash and the escape character, advancing `index`.
        mutating func parseEscape() throws(SchemaError) -> UInt32 {
            guard current == UInt8(ascii: "\\") else {
                throw SchemaError.parse("expected escape at \(describePosition())")
            }
            index += 1
            guard let escape = current else {
                throw SchemaError.parse("unterminated escape at \(describePosition())")
            }
            index += 1
            if let code = Self.shortEscapes[escape] { return code }
            if escape == UInt8(ascii: "u") { return try parseUnicodeEscape() }
            throw SchemaError.parse("bad escape at \(describePosition())")
        }

        mutating func parseHex4() throws(SchemaError) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let b = current else {
                    throw SchemaError.parse("truncated \\u escape at \(describePosition())")
                }
                let digit: UInt32
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    digit = UInt32(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"):
                    digit = UInt32(b - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"):
                    digit = UInt32(b - UInt8(ascii: "A")) + 10
                default:
                    throw SchemaError.parse("bad \\u escape digit at \(describePosition())")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        mutating func parseUnicodeEscape() throws(SchemaError) -> UInt32 {
            let first = try parseHex4()
            guard (0xD800...0xDBFF).contains(first) else { return first }
            // High surrogate: a matching low surrogate must follow.
            guard current == UInt8(ascii: "\\") else {
                throw SchemaError.parse("lone high surrogate at \(describePosition())")
            }
            index += 1
            guard current == UInt8(ascii: "u") else {
                throw SchemaError.parse("lone high surrogate at \(describePosition())")
            }
            index += 1
            let second = try parseHex4()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw SchemaError.parse("bad surrogate pair at \(describePosition())")
            }
            let high = UInt32(first - 0xD800) << 10
            let low = UInt32(second - 0xDC00)
            return 0x10000 + high + low
        }

        func appendUTF8(_ scalar: UInt32, to units: inout [UInt8]) {
            // Surrogate pairs are combined before this runs, so the scalar is
            // valid; anything else falls back to U+FFFD.
            let scalarValue = UnicodeScalar(scalar) ?? UnicodeScalar(0xFFFD)!
            for byte in String(scalarValue).utf8 {
                units.append(byte)
            }
        }

        mutating func parseNumber() throws(SchemaError) -> JSON {
            let start = index
            if current == UInt8(ascii: "-") { index += 1 }
            // Integer part: no leading zeros.
            switch current {
            case UInt8(ascii: "0"):
                index += 1
            case .some(UInt8(ascii: "1")...UInt8(ascii: "9")):
                scanDigits()
            default:
                throw SchemaError.parse("bad number at \(describePosition())")
            }
            var isDecimal = false
            if current == UInt8(ascii: ".") {
                isDecimal = true
                index += 1
                guard let b = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) else {
                    throw SchemaError.parse("bad number fraction at \(describePosition())")
                }
                scanDigits()
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                isDecimal = true
                try parseExponent()
            }
            guard let literal = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw SchemaError.parse("invalid UTF-8 in number at \(describePosition())")
            }
            if !isDecimal, let intValue = Int(literal) {
                return .int(intValue)
            }
            // Decimal literals are kept exact (no floating point). Guard the
            // exponent so canonicalization can expand it without overflow.
            if isDecimal, let ePos = literal.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                let exponentText = literal[literal.index(after: ePos)...]
                guard let exponent = Int(exponentText), abs(exponent) <= 4096 else {
                    throw SchemaError.parse("number out of range at \(describePosition())")
                }
            }
            return .decimal(literal)
        }

        /// Advances `index` past a run of ASCII digits.
        mutating func scanDigits() {
            while let b = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) {
                index += 1
            }
        }

        /// Parses the `e`/`E` exponent (sign and digits); advances `index`.
        mutating func parseExponent() throws(SchemaError) {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard let b = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) else {
                throw SchemaError.parse("bad number exponent at \(describePosition())")
            }
            scanDigits()
        }
    }
}
