// Host-mediated expression evaluation (ARCHITECTURE.md §7.3–§7.5).
//
// The engine's mechanics are expression-shaped at their parameter
// boundaries: rule conditions, scoring expressions, and follow rules
// arrive as CardExpr sources from the ruleset document. The engine
// package owns no expression evaluator; the host (RulesetKit) installs
// a runtime through `Engine` and mechanics call it through
// `EvalContext.eval`. Keeping the call surface here means the
// dependency arrow stays engine ← host, and a ruleset that never
// evaluates an expression never pays for the runtime.

/// A plain value the engine exchanges with the host expression runtime
/// (§7.3: "data the engine owns is supplied to the host as plain
/// values"). It mirrors the host's `Value` cases without importing it.
public enum EvalValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    /// A card by identity; `suit` is the suit spelling ("S","H","D","C",
    /// "T" for trumps) and `rank` the rank spelling, both empty for
    /// face-down instances.
    case card(id: String, suit: String, rank: String)
    case list([EvalValue])
    case record(name: String, fields: [String: EvalValue])

    /// The seat or team spelling this value carries, for bridging
    /// seat-scoped reads; null for anything else.
    public var seatOrTeam: String? {
        switch self {
        case .string(let s): return s
        case .list(let items): return items.first?.seatOrTeam
        default: return nil
        }
    }
}

/// One expression evaluation requested by a mechanic (§7.5). `pointer`
/// is the JSON pointer of the expression in the ruleset document, used
/// in faults; `contextual` carries the mechanic-supplied bindings (for
/// example `c` in a follow-rule condition, `bid` in an auction ladder
/// step) as plain values.
public struct EvalCall: Sendable, Equatable {
    public let pointer: String
    public let source: String
    public let ruleId: String?
    public let contextual: [String: EvalValue]

    public init(
        pointer: String, source: String, ruleId: String? = nil,
        contextual: [String: EvalValue] = [:]
    ) {
        self.pointer = pointer
        self.source = source
        self.ruleId = ruleId
        self.contextual = contextual
    }
}

/// Why a host expression call failed (§7.4: faults must be raised, not
/// swallowed). Mechanics map every case onto
/// `RuleViolation.engineFault(ruleId:pointer:)` — a null result is never
/// a substitute for a fault.
public enum EvalFailure: Error, Sendable {
    /// The expression's fuel budget ran out.
    case budget(pointer: String)
    /// Compile or evaluation fault; `detail` is the human message.
    case fault(pointer: String, detail: String)
}
