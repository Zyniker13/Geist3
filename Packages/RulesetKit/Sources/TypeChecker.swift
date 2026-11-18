import CardExpr

/// The name bindings visible while checking one expression (§7.3).
///
/// A scope carries the contextual bindings supplied by the construct being
/// checked (the canonical contextual bindings are consulted after those),
/// the lambda variables introduced by enclosing macros, the parameters of
/// the def whose body is being checked, and whether the expression runs in
/// a host-only evaluation context (§7.5): expressions the host evaluates
/// on the players' behalf may see hidden information.
public struct Scope: Sendable {
    /// Bindings supplied by the construct being checked.
    public var contextual: [String: ExprType]
    /// Lambda variables in scope (macro bodies).
    public var lambdas: [String: ExprType]
    /// The def's own parameters (def bodies).
    public var defParams: [String: ExprType]
    /// True when the checked expression is evaluated only by the host.
    public var hostOnly: Bool

    public init(
        contextual: [String: ExprType] = [:],
        lambdas: [String: ExprType] = [:],
        defParams: [String: ExprType] = [:],
        hostOnly: Bool = false
    ) {
        self.contextual = contextual
        self.lambdas = lambdas
        self.defParams = defParams
        self.hostOnly = hostOnly
    }

    /// The type a name resolves to among the contextual bindings,
    /// including the canonical ones (§7.3).
    public func contextualType(_ name: String) -> ExprType? {
        contextual[name] ?? canonicalContextual[name]
    }
}

/// Type-checks CardExpr expressions against a `TypeContext` (§7.2).
///
/// Every checked expression yields a `TypedExpr` whose bindings let the
/// evaluator resolve references without re-resolving names at run time.
/// Checking is deterministic and pure with respect to the context; all
/// scoping state (inference variables, the def cycle stack, host-only
/// taint) lives in the checker instance.
public struct TypeChecker {
    /// The ruleset information to check against.
    public let context: TypeContext

    private var nextVarID = 0
    private var checkingDefs: [String] = []
    var defTaint: [String: Bool] = [:]
    private var hostOnlyUsed = false

    private static let contextRoots: Set<String> = ["match", "deal", "options", "players", "trick"]

    public init(context: TypeContext) {
        self.context = context
    }

    /// Whether a def was found to use host-only constructs (§7.5 taint),
    /// directly or through another def it calls.
    public func isHostOnlyDef(_ name: String) -> Bool {
        defTaint[name] ?? false
    }

    /// Whether host-only constructs (§7.5) are permitted in this scope:
    /// inside a def body (checked with `hostOnly: true`) or whenever the
    /// ruleset is evaluated by the host itself.
    func hostOnlyAllowed(in scope: Scope) -> Bool {
        scope.hostOnly || context.evaluation == .host
    }

    /// Records that the expression being checked used a host-only
    /// construct (§7.5 taint).
    mutating func noteHostOnly() {
        hostOnlyUsed = true
    }

    // MARK: Entry points

    /// Checks one expression in the plain scope and returns its typed
    /// form with inference variables resolved.
    public mutating func check(_ ast: AST) throws -> TypedExpr {
        try check(ast, in: Scope())
    }

    /// Checks one expression in a scope and returns its typed form with
    /// inference variables resolved.
    public mutating func check(_ ast: AST, in scope: Scope) throws -> TypedExpr {
        resolveAll(try checkNode(ast, scope: scope))
    }

    /// Checks a def body against its own signature, recording whether the
    /// body uses host-only constructs (§7.5), directly or through other
    /// defs it calls. Defs may not recurse; the cycle is reported at the
    /// def whose body closes it.
    public mutating func checkDef(_ def: DefSignature) throws -> TypedExpr {
        if checkingDefs.contains(def.name) {
            throw TypeError(
                span: def.body.span,
                message: "def '\(def.name)' is recursive; defs cannot recurse (§7.2)"
            )
        }
        checkingDefs.append(def.name)
        let savedUsed = hostOnlyUsed
        hostOnlyUsed = false
        defer {
            checkingDefs.removeLast()
            hostOnlyUsed = savedUsed
        }
        let parameters = Dictionary(zip(def.params, def.types), uniquingKeysWith: { _, new in new })
        let body = try checkNode(def.body, scope: Scope(defParams: parameters, hostOnly: true))
        guard unify(def.result, body.type) != nil else {
            throw TypeError(
                span: def.body.span,
                message: "'\(def.name)' result: expected \(typeName(def.result)), got \(typeName(body.type))"
            )
        }
        defTaint[def.name] = hostOnlyUsed
        if hostOnlyUsed && context.evaluation != .host {
            throw TypeError(
                span: def.body.span,
                message: "'\(def.name)' uses host-only constructs (§7.5)"
            )
        }
        return body
    }

    // MARK: Dispatch

    mutating func checkNode(_ ast: AST, scope: Scope) throws -> TypedExpr {
        switch ast {
        case .int, .string, .bool, .null:
            return TypedExpr(node: ast, type: Self.literalType(of: ast))
        case .ident(let name, _):
            return try checkIdent(name, ast: ast, scope: scope)
        case .list:
            return try checkList(ast, scope: scope)
        case .unary:
            return try checkUnary(ast, scope: scope)
        case .binary:
            return try checkBinary(ast, scope: scope)
        case .ternary:
            return try checkTernary(ast, scope: scope)
        case .member:
            return try checkMember(ast, scope: scope)
        case .index:
            return try checkIndex(ast, scope: scope)
        case .call:
            return try checkCall(ast, scope: scope)
        }
    }

    /// The type of a literal node (`int`, `string`, `bool`, `null`).
    private static func literalType(of ast: AST) -> ExprType {
        switch ast {
        case .int: return .int
        case .string: return .literalString
        case .bool: return .bool
        case .null: return .literalNull
        default: return .any
        }
    }

    // MARK: Names

    private func checkIdent(_ name: String, ast: AST, scope: Scope) throws -> TypedExpr {
        if let type = scope.lambdas[name] {
            return TypedExpr(node: ast, type: type, binding: .lambda(name))
        }
        if let type = scope.defParams[name] {
            return TypedExpr(node: ast, type: type, binding: .defParam(name))
        }
        if let type = scope.contextualType(name) {
            return TypedExpr(node: ast, type: type, binding: .contextual(name))
        }
        if let type = context.contextual[name] {
            return TypedExpr(node: ast, type: type, binding: .contextual(name))
        }
        let hint =
            Self.contextRoots.contains(name)
            ? "'\(name)' is a context root; use \(name).<field>"
            : "unknown name '\(name)'"
        throw TypeError(span: ast.span, message: hint)
    }

    // MARK: Member access

    private mutating func checkMember(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .member(let base, let name, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a member node")
        }
        if let result = try staticRootAccess(base: base, name: name, span: span) {
            let typedBase = TypedExpr(node: base, type: result.type, binding: result.binding)
            return TypedExpr(node: ast, type: result.type, children: [typedBase], binding: result.binding)
        }
        let typedBase = try checkNode(base, scope: scope)
        guard let fields = recordFields(of: typedBase.type) else {
            throw TypeError(span: span, message: "type \(typeName(typedBase.type)) has no members")
        }
        guard let fieldType = fields[name] else {
            throw TypeError(span: span, message: "\(typeName(typedBase.type)) has no member '\(name)'")
        }
        return TypedExpr(node: ast, type: fieldType, children: [typedBase])
    }

    /// Static access into a context root: variable, option, field, or a
    /// host-provided record binding. Returns nil when `root` is not a
    /// context root, so ordinary member access (`c.suit`) falls through to
    /// the general path.
    func rootAccess(root: String, name: String, span: SourceSpan) throws -> (ExprType, Binding)? {
        if let variable = try varAccess(root: root, name: name, span: span) {
            return variable
        }
        if root == "options" {
            guard let type = context.options[name] else {
                throw TypeError(span: span, message: "unknown option 'options.\(name)'")
            }
            return (type, .option(name))
        }
        if root == "players", let field = PlayersField(rawValue: name) {
            return (field.type, .playersField(field))
        }
        if root == "trick", let field = TrickField(rawValue: name) {
            return (field.type, .trickField(field))
        }
        guard Self.contextRoots.contains(root) else { return nil }
        if case .record(let record) = context.contextual[root], let field = record.fields[name] {
            return (field, .contextual(root))
        }
        throw TypeError(span: span, message: "unknown field '\(root).\(name)'")
    }

    /// Static access into a context root when the member base is a bare
    /// context-root name (`match.trump`); nil when the base is not an
    /// identifier, so ordinary member access falls through.
    private func staticRootAccess(
        base: AST, name: String, span: SourceSpan
    ) throws -> (type: ExprType, binding: Binding)? {
        guard case .ident(let root, _) = base else { return nil }
        return try rootAccess(root: root, name: name, span: span)
    }

    /// `match.x` / `deal.x` access against the declared variables. A
    /// per-seat or per-team variable reads as a list of its values,
    /// indexed by seat or team number (§7.3). Returns nil when the name
    /// is not a declared variable of that store.
    private func varAccess(root: String, name: String, span: SourceSpan) throws -> (ExprType, Binding)? {
        guard root == "match" || root == "deal" else { return nil }
        let store: VarStore = root == "match" ? .match : .deal
        guard let decl = context.vars[name], decl.scope.store == store else { return nil }
        let type = decl.scope.isIndexed ? ExprType.list(decl.type) : decl.type
        return (type, .variable(VarRef(store: store, scope: decl.scope, name: name)))
    }

    /// The member fields of a record-typed expression: the canonical
    /// `card` / `contract` cases and record values.
    private func recordFields(of type: ExprType) -> [String: ExprType]? {
        switch type.unwrapped {
        case .card: return canonicalRecords["card"]?.fields
        case .record(let record): return record.fields
        default: return nil
        }
    }

    // MARK: Lists and indexing

    private mutating func checkList(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .list(let items, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a list node")
        }
        guard !items.isEmpty else {
            let variable = nextVarID
            nextVarID += 1
            return TypedExpr(node: ast, type: .list(.varType(variable)))
        }
        let first = try checkNode(items[0], scope: scope)
        var elementType = first.type
        var typedItems = [first]
        for item in items.dropFirst() {
            let typedItem = try checkNode(item, scope: scope)
            elementType = try unifyOrThrow(typedItem.type, elementType, item.span, "list element")
            typedItems.append(typedItem)
        }
        return TypedExpr(node: ast, type: .list(elementType), children: typedItems)
    }

    private mutating func checkIndex(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .index(let base, let index, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not an index node")
        }
        let typedBase = try checkNode(base, scope: scope)
        let typedIndex = try checkNode(index, scope: scope)
        // Per-team and per-seat variables are indexed by team or seat,
        // not by int (§7.3).
        if case .variable(let ref) = typedBase.binding, ref.scope.isIndexed {
            let wanted: ExprType = ref.store == .match ? .team : .seat
            guard unify(typedIndex.type, wanted) != nil else {
                let kind = ref.store == .match ? "team" : "seat"
                let message =
                    "index must be \(typeName(wanted)) for a per-\(kind) variable, "
                    + "got \(typeName(typedIndex.type))"
                throw TypeError(span: span, message: message)
            }
            guard case .list(let element) = typedBase.type.unwrapped else {
                throw TypeError(span: span, message: "cannot index into \(typeName(typedBase.type))")
            }
            return TypedExpr(node: ast, type: element, children: [typedBase, typedIndex])
        }
        guard case .list(let element) = typedBase.type.unwrapped else {
            throw TypeError(span: span, message: "cannot index into \(typeName(typedBase.type))")
        }
        guard unify(typedIndex.type, .int) != nil else {
            throw TypeError(span: span, message: "index must be int, got \(typeName(typedIndex.type))")
        }
        return TypedExpr(node: ast, type: element, children: [typedBase, typedIndex])
    }
}
