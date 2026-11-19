import CardExpr

/// Call checking: builtins, natives, and defs (TypeChecker extension).
extension TypeChecker {
    mutating func checkCall(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .call(let callee, let args, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a call node")
        }
        switch callee {
        case .ident(let name, _):
            return try checkNamedCall(name, args: args, ast: ast, span: span, scope: scope)
        case .member(let base, let name, _):
            return try checkMemberCall(base, name: name, args: args, ast: ast, scope: scope)
        default:
            throw TypeError(span: span, message: "expression is not callable")
        }
    }

    private mutating func checkNamedCall(
        _ name: String, args: [AST], ast: AST, span: SourceSpan, scope: Scope
    ) throws -> TypedExpr {
        if let builtin = BuiltinID(rawValue: name) {
            return try checkBuiltinCall(builtin, args: args, ast: ast, span: span, scope: scope)
        }
        if context.native(named: name) != nil {
            return try checkNativeCall(name, args: args, ast: ast, span: span, scope: scope)
        }
        if let def = context.defs[name] {
            return try checkDefCall(def, args: args, ast: ast, span: span, scope: scope)
        }
        throw TypeError(span: ast.span, message: "unknown function '\(name)'")
    }

    /// A member call is a namespaced native (`cribbage.handScore(…)`) or a
    /// collection macro (`.map(v, …)`).
    private mutating func checkMemberCall(
        _ base: AST, name: String, args: [AST], ast: AST, scope: Scope
    ) throws -> TypedExpr {
        if case .ident(let namespace, _) = base, context.native(named: "\(namespace).\(name)") != nil {
            return try checkNativeCall("\(namespace).\(name)", args: args, ast: ast, span: ast.span, scope: scope)
        }
        // Call syntax on a context-root field (`players.count(s)`) names the
        // dotted field in the error rather than treating the root as a list.
        // An unknown base (`cards.size()`) falls through to the macros.
        if case .ident(let root, _) = base {
            if (try? rootAccess(root: root, name: name, span: ast.span)) != nil {
                throw TypeError(span: ast.span, message: "'\(root).\(name)' is not callable")
            }
        }
        return try checkMacroCall(name, base: base, args: args, ast: ast, scope: scope)
    }

    // MARK: Builtins

    private mutating func checkBuiltinCall(
        _ builtin: BuiltinID, args: [AST], ast: AST, span: SourceSpan, scope: Scope
    ) throws -> TypedExpr {
        let typedArgs = try args.map { try checkNode($0, scope: scope) }
        if builtin == .zone {
            try checkZoneKnown(typedArgs, span: span)
        }
        let signatures = (builtinRegistry[builtin] ?? []).filter { $0.params.count == typedArgs.count }
        guard !signatures.isEmpty else {
            throw TypeError(span: span, message: "no '\(builtin.rawValue)' form takes \(typedArgs.count) argument(s)")
        }
        var failure = "arguments do not match any '\(builtin.rawValue)' form"
        for signature in signatures {
            if signature.hostOnly && !hostOnlyAllowed(in: scope) {
                failure = "'\(builtin.rawValue)' is host-only (§7.5)"
                continue
            }
            if builtin == .zone, let zone = zoneArg(in: typedArgs) {
                if zone.visibility != .publicZone && !ownsZoneArgument(typedArgs) {
                    if !hostOnlyAllowed(in: scope) {
                        failure = "zone '\(zone.id)' is not publicly visible (§7.5)"
                        continue
                    }
                    noteHostOnly()
                }
            }
            guard unifyAll(signature.params, typedArgs) != nil else { continue }
            if signature.hostOnly { noteHostOnly() }
            return TypedExpr(node: ast, type: signature.result, children: typedArgs, binding: .builtin(builtin))
        }
        throw TypeError(span: span, message: failure)
    }

    /// The declared zone a `zone(…)` call reads, when its id is a string
    /// literal that names a declared zone.
    private func zoneArg(in arguments: [TypedExpr]) -> ZoneInfo? {
        guard let first = arguments.first, case .string(let id, _) = first.node else { return nil }
        return context.zones[id]
    }

    /// Rejects a `zone('id')` call whose id is a string literal naming no
    /// declared zone; only enforced when at least one zone is declared.
    private func checkZoneKnown(_ arguments: [TypedExpr], span: SourceSpan) throws {
        guard case .string(let id, _)? = arguments.first?.node else { return }
        guard !context.zones.isEmpty, context.zones[id] == nil else { return }
        throw TypeError(span: span, message: "unknown zone '\(id)'")
    }

    /// Whether the zone's owner argument is exactly the contextual `seat`
    /// binding — the evaluator's own seat, which it may always read (§7.5).
    private func ownsZoneArgument(_ arguments: [TypedExpr]) -> Bool {
        guard arguments.count == 2, case .ident("seat", _) = arguments[1].node else { return false }
        return true
    }

    // MARK: Natives

    private mutating func checkNativeCall(
        _ name: String, args: [AST], ast: AST, span: SourceSpan, scope: Scope
    ) throws -> TypedExpr {
        guard let native = context.native(named: name) else {
            throw TypeError(span: span, message: "unknown native function '\(name)'")
        }
        let typedArgs = try args.map { try checkNode($0, scope: scope) }
        guard typedArgs.count == native.params.count else {
            throw TypeError(
                span: span, message: "'\(name)' takes \(native.params.count) argument(s), got \(typedArgs.count)")
        }
        guard unifyAll(native.params, typedArgs) != nil else {
            throw TypeError(span: span, message: "'\(name)' arguments do not match its signature")
        }
        return TypedExpr(node: ast, type: native.result, children: typedArgs, binding: .native(name))
    }

    // MARK: Defs

    private mutating func checkDefCall(
        _ def: DefSignature, args: [AST], ast: AST, span: SourceSpan, scope: Scope
    ) throws -> TypedExpr {
        let typedArgs = try args.map { try checkNode($0, scope: scope) }
        guard typedArgs.count == def.types.count else {
            throw TypeError(
                span: span, message: "'\(def.name)' takes \(def.types.count) argument(s), got \(typedArgs.count)")
        }
        guard unifyAll(def.types, typedArgs) != nil else {
            throw TypeError(span: span, message: "'\(def.name)' arguments do not match its signature")
        }
        _ = try checkDef(def)
        if defTaint[def.name] == true {
            noteHostOnly()
            if !hostOnlyAllowed(in: scope) {
                throw TypeError(span: span, message: "'\(def.name)' uses host-only constructs (§7.5)")
            }
        }
        return TypedExpr(node: ast, type: def.result, children: typedArgs, binding: .defCall(def.name))
    }
}
