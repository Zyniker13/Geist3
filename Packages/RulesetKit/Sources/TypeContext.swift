/// Everything the type checker needs to know about one ruleset.
///
/// The loader (P2.5) builds a context from a ruleset JSON; validation (P2.6)
/// checks every expression and def against it. `evaluation` selects how
/// host-only constructs are treated: in the `host` context they are
/// allowed, in the `ai` and `ui` contexts they are rejected (§7.4).
public struct TypeContext: Sendable {
    public enum EvaluationContext: String, Sendable {
        case host
        case ai
        case ui
    }

    /// Option types by name (`options.x`).
    public var options: [String: ExprType]
    /// Scoped variables by name (`match.x`, `deal.x`).
    public var vars: [String: VarBinding]
    /// Zones by id (`zone(…)`); visibility drives host-only checking.
    public var zones: [String: ZoneInfo]
    /// Natives by dotted name (`cribbage.handScore`).
    public var natives: [String: NativeSignature]
    /// Defs by name, with parsed signatures.
    public var defs: [String: DefSignature]
    /// Extra ambient bindings supplied by the host (rarely used).
    public var contextual: [String: ExprType]
    /// Named record types available in def signatures and member access.
    public var records: [String: RecordType]
    /// Which evaluator is checking.
    public var evaluation: EvaluationContext

    public init(
        evaluation: EvaluationContext = .host,
        options: [String: ExprType] = [:],
        vars: [String: VarBinding] = [:],
        zones: [String: ZoneInfo] = [:],
        natives: [String: NativeSignature] = [:],
        defs: [String: DefSignature] = [:],
        contextual: [String: ExprType] = [:],
        records: [String: RecordType] = [:]
    ) {
        self.evaluation = evaluation
        self.options = options
        self.vars = vars
        self.zones = zones
        self.natives = natives
        self.defs = defs
        self.contextual = contextual
        self.records = canonicalRecords.merging(records) { _, new in new }
    }
}
