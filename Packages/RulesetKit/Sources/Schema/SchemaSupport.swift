// Shared schema plumbing and the small schema structs used by both rulesets
// and overlays (§5.1–§5.5, §8.1).

import Foundation

/// The lossless codec contract for schema types. `path` lets errors point at
/// the document location ("phases[2].params.packets[0].each"); every type
/// re-emits exactly what it decoded, and shapes are closed — unknown keys
/// throw during decode.
public protocol JSONCodable: Sendable {
    init(json: JSON, path: String) throws(SchemaError)
    var json: JSON { get }
}

/// Primitives ride through the schema as their obvious JSON cases. The
/// schema's lossless JSON tree keeps int and decimal apart, so an integer
/// field must contain a JSON integer, not an integral decimal.
extension Int: JSONCodable {
    public init(json: JSON, path: String) throws(SchemaError) {
        guard let i = json.intValue else {
            throw SchemaError.wrongType(expected: "integer", path: path)
        }
        self = i
    }

    public var json: JSON { .int(self) }
}

extension String: JSONCodable {
    public init(json: JSON, path: String) throws(SchemaError) {
        guard let s = json.stringValue else {
            throw SchemaError.wrongType(expected: "string", path: path)
        }
        self = s
    }

    public var json: JSON { .string(self) }
}

extension JSONCodable {
    public init(json: JSON) throws(SchemaError) {
        try self.init(json: json, path: "$")
    }

    public init(data: Data, path: String) throws(SchemaError) {
        try self.init(json: try JSONParser.parse(data), path: path)
    }

    public init(data: Data) throws(SchemaError) {
        try self.init(json: try JSONParser.parse(data), path: "$")
    }

    public init(contentsOf url: URL, path: String) throws(SchemaError) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Keep the message path-free: file URLs never appear in diagnostics.
            throw SchemaError.parse("unreadable document file")
        }
        try self.init(data: data, path: path)
    }

    public var encodedData: Data {
        json.prettyString().data(using: .utf8)!
    }
}

// Make the raw tree itself Codable so every JSONCodable type gets a real
// Codable conformance in one place (the Mechanic.Params constraint needs
// Codable). Key order is not preserved through Foundation coders; the
// JSONCodable path is the lossless one.

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Decimal.self) {
            // Foundation's exact base-10 number bridges the transport layer;
            // the tree keeps the literal (canonicalization maps integral
            // forms onto .int on comparison).
            self = .decimal(value.description)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSON].self) {
            self = .array(value)
            return
        }
        self = .object(
            try container.decode([String: JSON].self)
                .map { JSONField(key: $0.key, value: $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .decimal(let literal):
            try container.encode(Decimal(string: literal))
        case .string(let s): try container.encode(s)
        case .array(let items): try container.encode(items)
        case .object(let fields):
            try container.encode(
                Dictionary(
                    uniqueKeysWithValues: fields.map { ($0.key, $0.value) }))
        }
    }
}

extension JSONCodable {
    public init(from decoder: any Decoder) throws {
        self = try Self(json: try JSON(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// Ordered reader over a JSON object's fields: typed fetches consume fields,
/// and `rejectLeftovers()` throws when anything is left, so decode fails on
/// unknown keys instead of silently dropping them.
struct FieldReader {
    private var fields: [JSONField]
    let path: String

    init(_ fields: [JSONField], path: String) {
        self.fields = fields
        self.path = path
    }

    init(_ json: JSON, path: String) throws(SchemaError) {
        guard let fields = json.fields else {
            throw SchemaError.notObject(path: path)
        }
        self.fields = fields
        self.path = path
    }

    /// Remaining (unconsumed) fields, in source order.
    mutating func leftovers() -> [JSONField] {
        defer { fields = [] }
        return fields
    }

    func childPath(_ key: String) -> String { "\(path).\(key)" }

    /// After all known keys are consumed, any remaining field is an unknown
    /// key in a closed shape — reject it rather than silently dropping it.
    mutating func rejectLeftovers() throws(SchemaError) {
        let rest = leftovers()
        guard rest.isEmpty else {
            throw SchemaError.wrongType(
                expected: "no unknown keys (found \(rest.map { $0.key }.joined(separator: ", ")))",
                path: path)
        }
    }

    private mutating func take(_ key: String) -> JSON? {
        guard let index = fields.firstIndex(where: { $0.key == key }) else { return nil }
        return fields.remove(at: index).value
    }

    // Required fetches

    mutating func string(_ key: String) throws(SchemaError) -> String {
        guard let value = take(key) else {
            throw SchemaError.missingKey(key, path: path)
        }
        guard let s = value.stringValue else {
            throw SchemaError.wrongType(expected: "string", path: childPath(key))
        }
        return s
    }

    mutating func bool(_ key: String) throws(SchemaError) -> Bool {
        guard let value = take(key) else {
            throw SchemaError.missingKey(key, path: path)
        }
        guard let b = value.boolValue else {
            throw SchemaError.wrongType(expected: "bool", path: childPath(key))
        }
        return b
    }

    mutating func int(_ key: String) throws(SchemaError) -> Int {
        guard let value = take(key) else {
            throw SchemaError.missingKey(key, path: path)
        }
        guard let i = value.intValue else {
            throw SchemaError.wrongType(expected: "int", path: childPath(key))
        }
        return i
    }

    mutating func value(_ key: String) throws(SchemaError) -> JSON {
        guard let value = take(key) else {
            throw SchemaError.missingKey(key, path: path)
        }
        return value
    }

    mutating func array<T: JSONCodable>(_ key: String) throws(SchemaError) -> [T] {
        let raw = try value(key)
        guard let items = raw.arrayValue else {
            throw SchemaError.wrongType(expected: "array", path: childPath(key))
        }
        return try items.enumerated().map { (index: Int, item: JSON) throws(SchemaError) in
            try T(json: item, path: "\(childPath(key))[\(index)]")
        }
    }

    mutating func decoded<T: JSONCodable>(_ key: String) throws(SchemaError) -> T {
        let raw = try value(key)
        return try T(json: raw, path: childPath(key))
    }

    /// Keyed object of raw JSON values, preserved verbatim (no per-value typing).
    mutating func keyedFields(_ key: String) throws(SchemaError) -> [JSONField] {
        let raw = try value(key)
        guard let fields = raw.fields else {
            throw SchemaError.wrongType(expected: "object", path: childPath(key))
        }
        return fields
    }

    // Optional fetches

    mutating func optionalString(_ key: String) throws(SchemaError) -> String? {
        guard let value = take(key) else { return nil }
        guard let s = value.stringValue else {
            throw SchemaError.wrongType(expected: "string", path: childPath(key))
        }
        return s
    }

    mutating func optionalBool(_ key: String) throws(SchemaError) -> Bool? {
        guard let value = take(key) else { return nil }
        guard let b = value.boolValue else {
            throw SchemaError.wrongType(expected: "bool", path: childPath(key))
        }
        return b
    }

    mutating func optionalInt(_ key: String) throws(SchemaError) -> Int? {
        guard let value = take(key) else { return nil }
        guard let i = value.intValue else {
            throw SchemaError.wrongType(expected: "int", path: childPath(key))
        }
        return i
    }

    mutating func optionalValue(_ key: String) -> JSON? {
        take(key)
    }

    mutating func optionalArray<T: JSONCodable>(_ key: String) throws(SchemaError) -> [T]? {
        guard let raw = take(key) else { return nil }
        guard let items = raw.arrayValue else {
            throw SchemaError.wrongType(expected: "array", path: childPath(key))
        }
        return try items.enumerated().map { (index: Int, item: JSON) throws(SchemaError) in
            try T(json: item, path: "\(childPath(key))[\(index)]")
        }
    }

    mutating func optionalDecoded<T: JSONCodable>(_ key: String) throws(SchemaError) -> T? {
        guard let raw = take(key) else { return nil }
        return try T(json: raw, path: childPath(key))
    }
}

// MARK: - Shared leaf types

/// A game expression in source form. Kept verbatim; parsing is the evaluator's
/// job (P2.4), and the loader never rewrites expression text.
public struct Expr: Equatable, Sendable, JSONCodable {
    public var source: String

    public init(source: String) {
        self.source = source
    }

    public init(json: JSON, path: String) throws(SchemaError) {
        guard let s = json.stringValue else {
            throw SchemaError.wrongType(expected: "string expression", path: path)
        }
        source = s
    }

    public var json: JSON { .string(source) }
}

/// Localized user-facing text: a default plus optional i18n keys (§5.1).
public struct Text: Equatable, Sendable, JSONCodable {
    public var defaultString: String
    public var key: String?

    public init(defaultString: String, key: String? = nil) {
        self.defaultString = defaultString
        self.key = key
    }

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        defaultString = try reader.string("default")
        key = try reader.optionalString("key")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let key { pairs.append(("key", .string(key))) }
        pairs.append(("default", .string(defaultString)))
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Provenance link to a rules source (§5.1); only URLs and titles are stored,
/// never copied rule text.
public struct SourceRef: Equatable, Sendable, JSONCodable {
    public var id: String
    public var title: String
    public var url: String
    public var role: String
    public var accessed: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        title = try reader.string("title")
        url = try reader.string("url")
        role = try reader.string("role")
        accessed = try reader.optionalString("accessed")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("title", .string(title)),
            ("url", .string(url)),
            ("role", .string(role)),
        ]
        if let accessed { pairs.append(("accessed", .string(accessed))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Public catalogue classification (§5.1).
public struct Classification: Equatable, Sendable, JSONCodable {
    public var pagat: String
    public var objective: String
    public var tags: [String]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        pagat = try reader.string("pagat")
        objective = try reader.string("objective")
        tags = try reader.array("tags")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("pagat", .string(pagat)),
            ("objective", .string(objective)),
            ("tags", .array(tags.map { .string($0) })),
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Seat/team shape of a game (§5.3). `teams` is a layout name such as
/// "partnershipOpposite"; the enumerated vocabulary is fixed by §6 and
/// validated later, so it is stored as a plain string here.
public struct PlayersSpec: Equatable, Sendable, JSONCodable {
    public var counts: [Int]
    public var defaultCount: Int
    public var teams: String
    public var seatNames: [String]?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        counts = try reader.array("counts")
        defaultCount = try reader.int("default")
        teams = try reader.string("teams")
        seatNames = try reader.optionalArray("seatNames")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("counts", .array(counts.map { .int($0) })),
            ("default", .int(defaultCount)),
            ("teams", .string(teams)),
        ]
        if let seatNames {
            pairs.append(("seatNames", .array(seatNames.map { .string($0) })))
        }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Deck description (§5.2). `base` is a pack template id ("french-52", …);
/// remove/add hold card faces such as "2C".
public struct DeckSpec: Equatable, Sendable, JSONCodable {
    public var base: String?
    public var copies: Int?
    public var remove: [String]?
    public var add: [String]?
    public var faces: String?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        base = try reader.optionalString("base")
        copies = try reader.optionalInt("copies")
        remove = try reader.optionalArray("remove")
        add = try reader.optionalArray("add")
        faces = try reader.optionalString("faces")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let base { pairs.append(("base", .string(base))) }
        if let copies { pairs.append(("copies", .int(copies))) }
        if let remove { pairs.append(("remove", .array(remove.map { .string($0) }))) }
        if let add { pairs.append(("add", .array(add.map { .string($0) }))) }
        if let faces { pairs.append(("faces", .string(faces))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// A settings option (§5.4): typed value, constraints, display text, and the
/// rule ids this option may change.
public struct OptionDecl: Equatable, Sendable, JSONCodable {
    public var id: String
    public var type: String
    public var defaultValue: JSON
    public var min: Int?
    public var max: Int?
    public var values: [JSON]?
    public var label: Text
    public var help: Text?
    public var rules: [String]
    public var group: String?
    public var locked: Bool?
    /// The resolved value written in during resolution (§8.1): the table's
    /// choice, or the (possibly overlay-patched) default. Absent in source
    /// files; only decoded documents carry it.
    public var value: JSON?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        type = try reader.string("type")
        defaultValue = try reader.value("default")
        min = try reader.optionalInt("min")
        max = try reader.optionalInt("max")
        values = reader.optionalValue("values")?.arrayValue
        label = try reader.decoded("label")
        help = try reader.optionalDecoded("help")
        rules = try reader.array("rules")
        group = try reader.optionalString("group")
        locked = try reader.optionalBool("locked")
        value = reader.optionalValue("value")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("type", .string(type)),
            ("default", defaultValue),
        ]
        if let min { pairs.append(("min", .int(min))) }
        if let max { pairs.append(("max", .int(max))) }
        if let values { pairs.append(("values", .array(values))) }
        pairs.append(("label", label.json))
        if let help { pairs.append(("help", help.json)) }
        pairs.append(("rules", .array(rules.map { .string($0) })))
        if let group { pairs.append(("group", .string(group))) }
        if let locked { pairs.append(("locked", .bool(locked))) }
        if let value { pairs.append(("value", value)) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// A named rule statement (§5.2); ids are the anchors overlay patches and the
/// validator refer to. Text is authored here, never imported from a source.
public struct RuleDecl: Equatable, Sendable, JSONCodable {
    public var id: String
    public var text: Text
    public var explain: Text?
    /// Marks tournament-official text that overlays may not touch (§8.2).
    public var locked: Bool?

    public init(id: String, text: Text) {
        self.id = id
        self.text = text
        explain = nil
        locked = nil
    }

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        text = try reader.decoded("text")
        explain = try reader.optionalDecoded("explain")
        locked = try reader.optionalBool("locked")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("text", text.json),
        ]
        if let explain { pairs.append(("explain", explain.json)) }
        if let locked { pairs.append(("locked", .bool(locked))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// A named typed variable with its initial expression (§5.2).
public struct VarDecl: Equatable, Sendable, JSONCodable {
    public var scope: String
    public var type: String
    public var initial: Expr

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        scope = try reader.string("scope")
        type = try reader.string("type")
        initial = try reader.decoded("initial")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("scope", .string(scope)),
            ("type", .string(type)),
            ("initial", initial.json),
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// A named zone (§5.2). `visibility` is a visibility vocabulary name or a
/// `{ "seats": <Expr<[Seat]>> }` object; `scope` is seat/team/global.
public struct ZoneDecl: Equatable, Sendable, JSONCodable {
    public enum Visibility: Equatable, Sendable {
        case named(String)
        case seats(Expr)
    }

    public var id: String
    public var scope: String
    public var visibility: Visibility
    public var ordered: Bool?
    public var faceDown: Bool?
    public var sort: String?
    public var owner: Expr?
    public var capacity: Int?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        id = try reader.string("id")
        scope = try reader.string("scope")
        let rawVisibility = try reader.value("visibility")
        if let name = rawVisibility.stringValue {
            visibility = .named(name)
        } else if let seatsExpr = rawVisibility["seats"], let fields = rawVisibility.fields,
            fields.count == 1
        {
            visibility = .seats(try Expr(json: seatsExpr, path: "\(path).visibility.seats"))
        } else {
            throw SchemaError.wrongType(
                expected: "visibility name or {seats: expr}",
                path: "\(path).visibility")
        }
        ordered = try reader.optionalBool("ordered")
        faceDown = try reader.optionalBool("faceDown")
        sort = try reader.optionalString("sort")
        owner = try reader.optionalDecoded("owner")
        capacity = try reader.optionalInt("capacity")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("id", .string(id)),
            ("scope", .string(scope)),
            ("visibility", visibilityJSON),
        ]
        if let ordered { pairs.append(("ordered", .bool(ordered))) }
        if let faceDown { pairs.append(("faceDown", .bool(faceDown))) }
        if let sort { pairs.append(("sort", .string(sort))) }
        if let owner { pairs.append(("owner", owner.json)) }
        if let capacity { pairs.append(("capacity", .int(capacity))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }

    private var visibilityJSON: JSON {
        switch visibility {
        case .named(let name):
            return .string(name)
        case .seats(let expr):
            return .object([JSONField(key: "seats", value: expr.json)])
        }
    }
}

/// Setup block (§5.2): who deals first and how the button moves.
public struct SetupSpec: Equatable, Sendable, JSONCodable {
    public var firstDealer: String
    public var dealerRotation: String

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        firstDealer = try reader.string("firstDealer")
        dealerRotation = try reader.string("dealerRotation")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("firstDealer", .string(firstDealer)),
            ("dealerRotation", .string(dealerRotation)),
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Match end condition (§5.2). `check`/`when` discriminate the shape;
/// `rank` is "score" or "points" (whose value ranks the table).
public struct EndDecl: Equatable, Sendable, JSONCodable {
    public var check: String
    public var when: Expr?
    public var rank: String
    public var ties: String
    public var rule: String?
    public var matchEffects: [Effect]?
    public var maxDeals: Int?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        check = try reader.string("check")
        when = try reader.optionalDecoded("when")
        rank = try reader.string("rank")
        ties = try reader.string("ties")
        rule = try reader.optionalString("rule")
        matchEffects = try reader.optionalArray("matchEffects")
        maxDeals = try reader.optionalInt("maxDeals")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = [
            ("check", .string(check))
        ]
        if let when { pairs.append(("when", when.json)) }
        pairs.append(("rank", .string(rank)))
        pairs.append(("ties", .string(ties)))
        if let rule { pairs.append(("rule", .string(rule))) }
        if let matchEffects {
            pairs.append(("matchEffects", .array(matchEffects.map { $0.json })))
        }
        if let maxDeals { pairs.append(("maxDeals", .int(maxDeals))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Display hints (§5.7): an open set of keys the UI may honor.
public struct DisplayHints: Equatable, Sendable, JSONCodable {
    public var layout: String?
    public var scoreSheet: JSON?
    public var showLastTrick: Bool?
    public var trickHistory: String?
    public var board: String?
    public var showContract: Bool?
    public var showVulnerability: Bool?
    public var showTrump: Bool?
    public var showMaker: Bool?
    public var auctionBox: Bool?
    public var announceCount: Bool?

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        layout = try reader.optionalString("layout")
        scoreSheet = reader.optionalValue("scoreSheet")
        showLastTrick = try reader.optionalBool("showLastTrick")
        trickHistory = try reader.optionalString("trickHistory")
        board = try reader.optionalString("board")
        showContract = try reader.optionalBool("showContract")
        showVulnerability = try reader.optionalBool("showVulnerability")
        showTrump = try reader.optionalBool("showTrump")
        showMaker = try reader.optionalBool("showMaker")
        auctionBox = try reader.optionalBool("auctionBox")
        announceCount = try reader.optionalBool("announceCount")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        var pairs: [(String, JSON)] = []
        if let layout { pairs.append(("layout", .string(layout))) }
        if let scoreSheet { pairs.append(("scoreSheet", scoreSheet)) }
        if let showLastTrick { pairs.append(("showLastTrick", .bool(showLastTrick))) }
        if let trickHistory { pairs.append(("trickHistory", .string(trickHistory))) }
        if let board { pairs.append(("board", .string(board))) }
        if let showContract { pairs.append(("showContract", .bool(showContract))) }
        if let showVulnerability { pairs.append(("showVulnerability", .bool(showVulnerability))) }
        if let showTrump { pairs.append(("showTrump", .bool(showTrump))) }
        if let showMaker { pairs.append(("showMaker", .bool(showMaker))) }
        if let auctionBox { pairs.append(("auctionBox", .bool(auctionBox))) }
        if let announceCount { pairs.append(("announceCount", .bool(announceCount))) }
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// AI hints (§5.7): profile name plus opaque parameter object, preserved
/// verbatim (presence of an empty object is itself meaningful).
public struct AIHints: Equatable, Sendable, JSONCodable {
    public var profile: String
    public var params: [JSONField]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        profile = try reader.string("profile")
        params = try reader.keyedFields("params")  // values stay raw JSON
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("profile", .string(profile)),
            ("params", .object(params)),
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}

/// Teaching hints (§5.7): lesson ids the tutorial layer can reference.
public struct TeachingHints: Equatable, Sendable, JSONCodable {
    public var lessons: [String]

    public init(json: JSON, path: String) throws(SchemaError) {
        var reader = try FieldReader(json, path: path)
        lessons = try reader.array("lessons")
        try reader.rejectLeftovers()
    }

    public var json: JSON {
        let pairs: [(String, JSON)] = [
            ("lessons", .array(lessons.map { .string($0) }))
        ]
        return .object(pairs.map { JSONField(key: $0.0, value: $0.1) })
    }
}
