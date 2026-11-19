import CardExpr

/// Member access, indexing, calls, builtins, macros, and defs
/// (Evaluator extension).
extension Evaluator {
    // MARK: Member access

    mutating func evaluateMember(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        // A static context-root member (`match.x`, `players.count`,
        // `trick.winner`) carries its binding on the member node itself;
        // the ident child is the root and is not re-evaluated.
        switch typed.binding {
        case .option, .variable:
            return try storedBindingValue(typed)
        case .trickField(let field):
            return trickValue(field)
        case .playersField(let field):
            switch field {
            case .count:
                return .int(Int64(env.playersCount))
            case .active:
                return .int(Int64(env.activeSeats.count))
            }
        case .dealIndex:
            return .int(Int64(env.dealIndex))
        case .contextual(let root):
            // A record-valued context root (`call.level`): read the field.
            let base = try evaluateRoot(root)
            return try readField(base, name: memberName(typed), ofRoot: root)
        case .none:
            let base = try walk(typed.children[0])
            return try readField(base, name: memberName(typed), ofRoot: nil)
        default:
            return try fault(.unsupportedValue, "internal: unexpected binding on member access")
        }
    }

    /// Statically-resolved stored bindings (options and plain variables)
    /// read directly out of the environment.
    private mutating func storedBindingValue(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        switch typed.binding {
        case .option(let name):
            guard let value = env.optionValues[name] else {
                return try fault(.unsupportedValue, "internal: option '\(name)' is not bound")
            }
            return value
        case .variable(let ref):
            guard let value = env.plainVars[ref] else {
                return try fault(.unsupportedValue, "internal: variable '\(ref.name)' is not bound")
            }
            return value
        default:
            return try fault(.unsupportedValue, "internal: stored binding is not an option or variable")
        }
    }

    /// The member name of a member node.
    private func memberName(_ typed: TypedExpr) -> String {
        if case .member(_, let name, _) = typed.node { return name }
        return ""
    }

    /// A record-valued context root binding (`call`, `param`).
    private mutating func evaluateRoot(_ root: String) throws(EvaluationFault) -> Value {
        guard let value = env.contextual[root] else {
            return try fault(.unsupportedValue, "contextual binding '\(root)' is not bound here")
        }
        return value
    }

    mutating func readField(_ base: Value, name: String, ofRoot root: String?) throws(EvaluationFault) -> Value {
        switch base {
        case .card(let id, let suit, let rank):
            switch name {
            case "id": return .string(id)
            case "suit": return .string(suit)
            case "rank": return .string(rank)
            default: break
            }
        case .record(_, let fields):
            if let value = fields[name] { return value }
        case .null:
            return try fault(.nullDereference, "null has no member '\(name)'")
        default:
            break
        }
        let owner = root.map { " on '\($0)'" } ?? ""
        return try fault(.unsupportedValue, "value has no member '\(name)'\(owner)")
    }

    // MARK: Indexing

    mutating func evaluateIndex(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        // Fused indexed-variable reads (`deal.scores['N']`) are resolved
        // before the base member is walked: that member is only bound
        // through the indexed path, so walking it first faults 'not bound'.
        if case .variable(let ref) = typed.children[0].binding, ref.scope.isIndexed {
            let index = try walk(typed.children[1])
            return try indexedVarValue(ref, at: index)
        }
        let base = try walk(typed.children[0])
        let index = try walk(typed.children[1])
        switch (base, index) {
        case (.null, _):
            return try fault(.nullDereference, "cannot index null")
        case (.list(let items), .int(let i)):
            guard i >= 0 && i < Int64(items.count) else {
                return try fault(.indexOutOfRange, "index \(i) out of range for \(items.count) element(s)")
            }
            return items[Int(i)]
        default:
            return try fault(.unsupportedValue, "cannot index this value")
        }
    }

    /// Per-seat and per-team variables are positional lists, ordered by
    /// the environment's seat or team order (§7.3); the index value
    /// selects the position.
    private func indexedVarValue(_ ref: VarRef, at index: Value) throws(EvaluationFault) -> Value {
        let key: String
        switch index {
        case .string(let s): key = s
        case .null:
            return try fault(.nullDereference, "cannot index variable '\(ref.name)' with null")
        default:
            return try fault(.unsupportedValue, "internal: variable index is not a seat or team")
        }
        guard let values = env.indexedVars[ref] else {
            return try fault(.unsupportedValue, "internal: variable '\(ref.name)' is not bound")
        }
        let order = ref.scope.store == .match ? env.teams : env.seats
        guard let position = order.firstIndex(where: { $0 == index }) else {
            let store = ref.scope.store == .match ? "team" : "seat"
            return try fault(.indexOutOfRange, "'\(key)' is not in the \(store) order")
        }
        guard position < values.count else {
            return try fault(.indexOutOfRange, "variable '\(ref.name)' has no value for '\(key)'")
        }
        return values[position]
    }

    // MARK: Calls

    mutating func evaluateCall(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        switch typed.binding {
        case .builtin(let builtin):
            return try evaluateBuiltin(builtin, typed)
        case .native(let name):
            return try evaluateNative(name, typed)
        case .defCall(let name):
            return try evaluateDefCall(name, typed)
        case .macro(let macro):
            return try evaluateMacro(macro, typed)
        case .none:
            return try fault(.unsupportedValue, "internal: call has no binding")
        default:
            return try fault(.unsupportedValue, "internal: unexpected binding on call")
        }
    }

    mutating func evaluateNative(_ name: String, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        guard let native = env.natives[name] else {
            return try fault(.unsupportedValue, "internal: native '\(name)' has no implementation")
        }
        var arguments: [Value] = []
        arguments.reserveCapacity(typed.children.count)
        for child in typed.children {
            arguments.append(try walk(child))
        }
        return try native(arguments)
    }

    /// A def call: the def's body is checked lazily against the context
    /// (it was validated at load), its parameters bound to the argument
    /// values, and the body evaluated.
    mutating func evaluateDefCall(_ name: String, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        guard let def = context.defs[name] else {
            return try fault(.unsupportedValue, "internal: def '\(name)' is not in the context")
        }
        var arguments: [Value] = []
        arguments.reserveCapacity(typed.children.count)
        for child in typed.children {
            arguments.append(try walk(child))
        }
        let body: TypedExpr
        if let cached = defBodies[name] {
            body = cached
        } else {
            var checker = TypeChecker(context: context)
            do {
                body = try checker.checkDef(def)
            } catch let error as TypeError {
                return try fault(.unsupportedValue, "internal: def '\(name)' failed to check: \(error.message)")
            } catch {
                return try fault(.unsupportedValue, "internal: def '\(name)' failed to check")
            }
            defBodies[name] = body
        }
        let saved = defParamBindings
        defParamBindings = Dictionary(zip(def.params, arguments), uniquingKeysWith: { _, new in new })
        defer { defParamBindings = saved }
        return try walk(body)
    }

    /// The trick snapshot fields (§7.3).
    private func trickValue(_ field: TrickField) -> Value {
        switch field {
        case .number: return env.trick.number
        case .leader: return env.trick.leader
        case .cards: return env.trick.cards
        case .ledSuit: return env.trick.ledSuit
        case .winner: return env.trick.winner
        }
    }
}
