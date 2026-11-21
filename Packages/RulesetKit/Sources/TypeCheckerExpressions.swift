import CardExpr
import Foundation

/// Collection macros and operator typing (TypeChecker extension).
extension TypeChecker {
    // MARK: Macros

    mutating func checkMacroCall(
        _ name: String, base: AST, args: [AST], ast: AST, scope: Scope
    ) throws -> TypedExpr {
        let span = ast.span
        guard let macro = MacroID(rawValue: name) else {
            throw TypeError(span: span, message: "unknown macro '.\(name)'")
        }
        let typedBase = try checkNode(base, scope: scope)
        guard case .list(let element) = typedBase.type.unwrapped else {
            throw TypeError(span: span, message: "'.\(name)' requires a list receiver, got \(typeName(typedBase.type))")
        }
        if macro.lambda {
            guard args.count == 2, case .ident(let variable, _) = args[0] else {
                throw TypeError(span: span, message: "'.\(name)' takes a variable name and an expression")
            }
            var inner = scope
            inner.lambdas[variable] = element
            let body = try checkNode(args[1], scope: inner)
            return try finishLambdaMacro(macro, receiver: typedBase, body: body, element: element, ast: ast)
        }
        let expected = macro == .contains ? 1 : 0
        guard args.count == expected else {
            let want = expected == 0 ? "no arguments" : "one argument"
            throw TypeError(span: span, message: "'.\(name)' takes \(want)")
        }
        let body = expected == 0 ? nil : try checkNode(args[0], scope: scope)
        return try finishPlainMacro(macro, receiver: typedBase, body: body, element: element, ast: ast)
    }

    private func finishLambdaMacro(
        _ macro: MacroID, receiver: TypedExpr, body: TypedExpr, element: ExprType, ast: AST
    ) throws -> TypedExpr {
        let span = ast.span
        let children = [receiver, body]
        switch macro {
        case .map:
            return TypedExpr(node: ast, type: .list(body.type), children: children, binding: .macro(macro))
        case .filter:
            try requirePredicate(macro, body.type, span)
            return TypedExpr(node: ast, type: .list(element), children: children, binding: .macro(macro))
        case .exists, .all:
            try requirePredicate(macro, body.type, span)
            return TypedExpr(node: ast, type: .bool, children: children, binding: .macro(macro))
        case .count:
            try requirePredicate(macro, body.type, span)
            return TypedExpr(node: ast, type: .int, children: children, binding: .macro(macro))
        case .sortBy:
            let key = body.type.unwrapped
            if unify(key, .int) == nil && unify(key, .string) == nil {
                throw TypeError(
                    span: span,
                    message: "'.sortBy' key must be int or string, got \(typeName(body.type))"
                )
            }
            return TypedExpr(node: ast, type: .list(element), children: children, binding: .macro(macro))
        default:
            throw TypeError(span: span, message: "internal: '\(macro.rawValue)' is not a lambda macro")
        }
    }

    private func requirePredicate(_ macro: MacroID, _ type: ExprType, _ span: SourceSpan) throws {
        guard unify(type, .bool) != nil else {
            throw TypeError(span: span, message: "'.\(macro.rawValue)' body must be bool, got \(typeName(type))")
        }
    }

    private func finishPlainMacro(
        _ macro: MacroID, receiver: TypedExpr, body: TypedExpr?, element: ExprType, ast: AST
    ) throws -> TypedExpr {
        let span = ast.span
        let children = body.map { [receiver, $0] } ?? [receiver]
        switch macro {
        case .sum:
            guard unify(element, .int) != nil else {
                throw TypeError(span: span, message: "'.sum' needs int elements, got \(typeName(element))")
            }
            return TypedExpr(node: ast, type: .int, children: children, binding: .macro(macro))
        case .size:
            return TypedExpr(node: ast, type: .int, children: children, binding: .macro(macro))
        case .contains:
            guard let body else {
                throw TypeError(span: span, message: "internal: '.contains' without an argument")
            }
            guard unify(body.type, element) != nil else {
                throw TypeError(
                    span: span,
                    message: "'.contains' argument \(typeName(body.type)) does not match element \(typeName(element))"
                )
            }
            return TypedExpr(node: ast, type: .bool, children: children, binding: .macro(macro))
        case .min, .max, .first:
            return TypedExpr(node: ast, type: .optional(element), children: children, binding: .macro(macro))
        default:
            throw TypeError(span: span, message: "internal: '\(macro.rawValue)' is not a plain macro")
        }
    }

    // MARK: Operators

    mutating func checkUnary(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .unary(let op, let operand, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a unary node")
        }
        let typed = try checkNode(operand, scope: scope)
        switch op {
        case .not:
            _ = try unifyOrThrow(typed.type, .bool, span, "'!' operand")
            return TypedExpr(node: ast, type: .bool, children: [typed])
        case .negate:
            _ = try unifyOrThrow(typed.type, .int, span, "'-' operand")
            return TypedExpr(node: ast, type: .int, children: [typed])
        default:
            throw TypeError(span: span, message: "internal: '\(op.symbol)' is not unary")
        }
    }

    mutating func checkBinary(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .binary(let op, let lhs, let rhs, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a binary node")
        }
        let typedLhs = try checkNode(lhs, scope: scope)
        let typedRhs = try checkNode(rhs, scope: scope)
        switch op {
        case .and, .or:
            return try booleanOp(op, ast: ast, lhs: typedLhs, rhs: typedRhs, span: span)
        case .eq, .neq:
            return try equalityOp(op, ast: ast, lhs: typedLhs, rhs: typedRhs, span: span)
        case .lt, .le, .gt, .ge:
            try requireIntOperands(op, typedLhs, typedRhs, span)
            return TypedExpr(node: ast, type: .bool, children: [typedLhs, typedRhs])
        case .inOp:
            return try membershipOp(ast, lhs: typedLhs, rhs: typedRhs, span: span)
        case .add, .sub, .mul, .div, .mod:
            try requireIntOperands(op, typedLhs, typedRhs, span)
            return TypedExpr(node: ast, type: .int, children: [typedLhs, typedRhs])
        default:
            throw TypeError(span: span, message: "internal: '\(op.symbol)' is not binary")
        }
    }

    private func booleanOp(
        _ op: AST.Operator, ast: AST, lhs: TypedExpr, rhs: TypedExpr, span: SourceSpan
    ) throws -> TypedExpr {
        _ = try unifyOrThrow(lhs.type, .bool, span, "'\(op.symbol)' left operand")
        _ = try unifyOrThrow(rhs.type, .bool, span, "'\(op.symbol)' right operand")
        return TypedExpr(node: ast, type: .bool, children: [lhs, rhs])
    }

    private func equalityOp(
        _ op: AST.Operator, ast: AST, lhs: TypedExpr, rhs: TypedExpr, span: SourceSpan
    ) throws -> TypedExpr {
        guard unify(lhs.type, rhs.type) != nil else {
            throw TypeError(
                span: span,
                message: "'\(op.symbol)' cannot compare \(typeName(lhs.type)) with \(typeName(rhs.type))"
            )
        }
        return TypedExpr(node: ast, type: .bool, children: [lhs, rhs])
    }

    /// Comparison and arithmetic operators take int operands (§7.2).
    /// Optional operands are accepted by unwrapping: a null operand
    /// dereferences at runtime (§7.6), so optionality is not a type error.
    private func requireIntOperands(
        _ op: AST.Operator, _ lhs: TypedExpr, _ rhs: TypedExpr, _ span: SourceSpan
    ) throws {
        for side in [lhs.type.unwrapped, rhs.type.unwrapped] where unify(side, .int) == nil {
            throw TypeError(span: span, message: "'\(op.symbol)' takes int operands, got \(typeName(side))")
        }
    }

    private func membershipOp(_ ast: AST, lhs: TypedExpr, rhs: TypedExpr, span: SourceSpan) throws -> TypedExpr {
        guard case .list(var element) = rhs.type.unwrapped else {
            throw TypeError(span: span, message: "'in' needs a list on the right, got \(typeName(rhs.type))")
        }
        // Membership searches nested lists too: a card "in hands" (a list of
        // list of card) is found inside any hand (§7.2).
        var depth = 0
        while unify(lhs.type, element) == nil, case .list(let inner) = element, depth < 8 {
            element = inner
            depth += 1
        }
        guard unify(lhs.type, element) != nil else {
            throw TypeError(span: span, message: "\(typeName(lhs.type)) cannot appear in \(typeName(rhs.type))")
        }
        return TypedExpr(node: ast, type: .bool, children: [lhs, rhs])
    }

    mutating func checkTernary(_ ast: AST, scope: Scope) throws -> TypedExpr {
        guard case .ternary(let condition, let thenAST, let elseAST, let span) = ast else {
            throw TypeError(span: ast.span, message: "internal: not a ternary node")
        }
        let typedCondition = try checkNode(condition, scope: scope)
        let typedThen = try checkNode(thenAST, scope: scope)
        let typedElse = try checkNode(elseAST, scope: scope)
        _ = try unifyOrThrow(typedCondition.type, .bool, span, "ternary condition")
        guard let result = unify(typedThen.type, typedElse.type) else {
            throw TypeError(
                span: span,
                message: "ternary branches differ: \(typeName(typedThen.type)) vs \(typeName(typedElse.type))"
            )
        }
        return TypedExpr(node: ast, type: result, children: [typedCondition, typedThen, typedElse])
    }
}
