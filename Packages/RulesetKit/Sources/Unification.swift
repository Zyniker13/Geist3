import CardExpr

// MARK: - Unification (§7.4)

extension TypeChecker {
    /// Unifies two types: equal types, `any` and `null` accept and adopt
    /// the other side, string literals adopt any string-domained type and
    /// vice versa, optionals accept their payload type and vanish into
    /// it, list elements unify pairwise, and inference variables adopt
    /// the other side. Returns nil when the types are incompatible.
    func unify(_ lhs: ExprType, _ rhs: ExprType) -> ExprType? {
        if lhs == rhs { return lhs }
        switch (lhs, rhs) {
        case (.union(let members), let other), (let other, .union(let members)):
            return unifyWithUnion(members, other)
        case (.any, let other), (let other, .any),
            (.literalNull, let other), (let other, .literalNull):
            return other
        case (.literalString, let other) where other.isStringDomain:
            return other
        case (let other, .literalString) where other.isStringDomain:
            return other
        case (.list(let innerLhs), .list(let innerRhs)):
            return unify(innerLhs, innerRhs).map(ExprType.list)
        case (.varType, let other), (let other, .varType):
            return other
        case (.optional(let innerLhs), .optional(let innerRhs)):
            return unify(innerLhs, innerRhs).map(ExprType.optional)
        case (.optional(let innerLhs), let other), (let other, .optional(let innerLhs)):
            return unify(innerLhs, other).map(ExprType.optional)
        default:
            return nil
        }
    }

    /// Unifies a union type with the other side: a string literal never
    /// enters a union (ambiguous with several string-domained members),
    /// `null` stays a union, and anything else joins the first member
    /// that accepts it.
    private func unifyWithUnion(_ members: [ExprType], _ other: ExprType) -> ExprType? {
        if case .literalString = other { return nil }
        if case .literalNull = other { return .union(members) }
        for member in members where unify(other, member) != nil {
            return unify(other, member)
        }
        return nil
    }

    /// Unifies `actual` with `expected`, throwing a type error on failure.
    func unifyOrThrow(_ actual: ExprType, _ expected: ExprType, _ span: SourceSpan, _ what: String) throws -> ExprType {
        guard let unified = unify(actual, expected) else {
            throw TypeError(
                span: span,
                message: "\(what): expected \(typeName(expected)), got \(typeName(actual))"
            )
        }
        return unified
    }

    /// Unifies each argument type with its parameter type positionally;
    /// nil when any pair fails or the counts differ.
    func unifyAll(_ params: [ExprType], _ arguments: [TypedExpr]) -> [ExprType]? {
        guard params.count == arguments.count else { return nil }
        var unified: [ExprType] = []
        for (parameter, argument) in zip(params, arguments) {
            guard let type = unify(argument.type, parameter) else { return nil }
            unified.append(type)
        }
        return unified
    }

    /// Replaces unresolved inference variables with `any` before a checked
    /// expression is exposed; only empty list literals can leave them.
    func resolveInference(_ type: ExprType) -> ExprType {
        switch type {
        case .varType: return .any
        case .list(let element): return .list(resolveInference(element))
        case .optional(let inner): return .optional(resolveInference(inner))
        default: return type
        }
    }

    /// Rebuilds a typed expression with inference variables resolved.
    func resolveAll(_ typed: TypedExpr) -> TypedExpr {
        TypedExpr(
            node: typed.node,
            type: resolveInference(typed.type),
            children: typed.children.map(resolveAll),
            binding: typed.binding
        )
    }
}
