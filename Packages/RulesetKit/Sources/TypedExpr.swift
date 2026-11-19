import CardExpr

/// How a name in an expression was resolved, for the evaluator.
///
/// The evaluator walks a `TypedExpr` and uses the binding of each
/// identifier, member, or call node to fetch or compute a value without
/// re-resolving names at run time.
public enum Binding: Sendable, Hashable {
    /// `options.x`
    case option(String)
    /// `match.x` / `deal.x`
    case variable(VarRef)
    /// A contextual binding (§7.3): `dealer`, `c`, `param`, …
    case contextual(String)
    /// `trick.number`, `trick.winner`, …
    case trickField(TrickField)
    /// `players.count`, `players.active`
    case playersField(PlayersField)
    /// `deal.index`
    case dealIndex
    /// A macro lambda parameter (`v` in `.map(v, …)`).
    case lambda(String)
    /// A def's own parameter.
    case defParam(String)
    /// A builtin call: `zone(…)`, `holderOf(…)`, …
    case builtin(BuiltinID)
    /// A call to a ruleset def.
    case defCall(String)
    /// A namespaced native call: `cribbage.handScore(…)`.
    case native(String)
    /// A macro call: `.map(v, …)`, `.sum()`, …
    case macro(MacroID)
}

/// A checked expression: the AST node, its inferred type, bindings for
/// every resolvable reference, and typed children in a fixed shape the
/// evaluator can walk.
///
/// Children shapes: `.list` → elements; `.unary` → `[operand]`; `.binary`
/// → `[lhs, rhs]`; `.ternary` → `[cond, then, else]`; `.member`/`.index`
/// → `[base, (index)]`; builtin/def/native calls → arguments; macro calls
/// → `[receiver, lambdaBody]`.
public struct TypedExpr: Sendable {
    public let node: AST
    public let type: ExprType
    public let children: [TypedExpr]
    public let binding: Binding?
    /// A folded constant (§7.4): when set, evaluation returns this value
    /// directly without walking the tree. Set only by the constant
    /// folder, and only for subexpressions that cannot fault and read
    /// nothing from the environment.
    public let constant: Value?

    public init(
        node: AST, type: ExprType, children: [TypedExpr] = [], binding: Binding? = nil, constant: Value? = nil
    ) {
        self.node = node
        self.type = type
        self.children = children
        self.binding = binding
        self.constant = constant
    }

    /// The source span of the underlying node.
    public var span: SourceSpan { node.span }

    /// The variable this node reads, when it is a scoped-variable access.
    public var varRef: VarRef? {
        if case .variable(let ref) = binding { return ref }
        return nil
    }

    /// The first child: member/index base, binary lhs, unary operand,
    /// ternary condition, call argument list, macro receiver.
    public var first: TypedExpr? { children.first }

    /// The second child: index expression, binary rhs, ternary then-branch,
    /// macro lambda body.
    public var second: TypedExpr? { children.count > 1 ? children[1] : nil }

    /// The third child: ternary else-branch.
    public var third: TypedExpr? { children.count > 2 ? children[2] : nil }
}
