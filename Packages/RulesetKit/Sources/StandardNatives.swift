import CardExpr

/// Reference implementations of the §5.8 natives the reference rulesets
/// call. The engine installs `all(teams:)` into `EvaluationEnvironment.natives`;
/// tests install it directly. Every failure raises `EvaluationFault` with
/// kind `unsupportedValue` and a `natives/<name>` pointer; the engine maps it
/// onto a rule violation carrying the expression's real pointer.
///
/// Scoring semantics (ADR-0025):
/// - `bridge.score` `total` counts the declarer side only (`below + above`);
///   a set contract reports the penalty through `defenders` alone, which is
///   how the Chicago overlay awards both sides.
/// - Chicago and duplicate use per-deal bonus scoring (game 300/500,
///   part-score 50); rubber leaves game and part bonuses to the match store.
/// - `bridge.honors` resolves its team argument against the `teams` list the
///   host installs: team index `i` holds the alternating seats `j % 2 == i`
///   (§5.4 partnershipOpposite).
/// - `rummy.melds` returns an optimal meld partition: minimal deadwood, ties
///   broken by the first partition the deterministic search reaches. Melds
///   must contain at least one natural card.
public enum StandardNatives {

    /// The implementation type `EvaluationEnvironment.natives` stores.
    public typealias Impl = @Sendable ([Value]) throws(EvaluationFault) -> Value

    /// All reference natives. `teams` is the ruleset's ordered team list;
    /// `bridge.honors` needs it to map a team to its two seats.
    public static func all(teams: [Value] = []) -> [String: Impl] {
        return [
            "cribbage.handScore": cribbageHandScore,
            "cribbage.pegPoints": cribbagePegPoints,
            "bridge.score": bridgeScore,
            "bridge.honors": bridgeHonors(teams: teams),
            "rummy.melds": rummyMelds,
        ]
    }

    // MARK: - Argument helpers

    static func fault(_ call: String, _ message: String) throws(EvaluationFault) -> Never {
        throw EvaluationFault(
            kind: .unsupportedValue, pointer: "natives/\(call)", message: message)
    }

    static func intArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> Int {
        guard case .int(let n) = v else {
            try fault(call, "\(label) must be an int")
        }
        return Int(n)
    }

    static func boolArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> Bool {
        guard case .bool(let b) = v else {
            try fault(call, "\(label) must be a bool")
        }
        return b
    }

    static func stringArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> String {
        guard case .string(let s) = v else {
            try fault(call, "\(label) must be a string")
        }
        return s
    }

    static func cardArg(_ v: Value, _ call: String) throws(EvaluationFault) -> Value {
        guard case .card = v else {
            try fault(call, "expected a card")
        }
        return v
    }

    static func cardListArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> [Value] {
        guard case .list(let items) = v else {
            try fault(call, "\(label) must be a list of cards")
        }
        for item in items {
            guard case .card = item else {
                try fault(call, "\(label) must be a list of cards")
            }
        }
        return items
    }

    static func recordArg(
        _ v: Value, _ name: String, _ call: String
    ) throws(EvaluationFault) -> [String: Value] {
        guard case .record(let recordName, let fields) = v, recordName == name else {
            try fault(call, "expected a \(name) record")
        }
        return fields
    }

    static func recordField(
        _ fields: [String: Value], _ key: String, _ call: String
    ) throws(EvaluationFault) -> Value {
        guard let v = fields[key] else {
            try fault(call, "record is missing field '\(key)'")
        }
        return v
    }

    /// The pip value of a rank (§5.2, §5.3): ace 1, cards 2–10 face value,
    /// court cards 10.
    static func pip(rank: String) -> Int? {
        if rank == "A" { return 1 }
        if let n = Int(rank), (2...10).contains(n) { return n }
        if ["J", "Q", "K"].contains(rank) { return 10 }
        return nil
    }

    static func pipOrFault(
        rank: String, call: String
    ) throws(EvaluationFault) -> Int {
        guard let value = pip(rank: rank) else {
            try fault(call, "card of rank '\(rank)' has no pip value")
        }
        return value
    }

    /// The standard french rank order, ace low, as indices 0…12.
    static let frenchRanks = [
        "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
    ]

}
