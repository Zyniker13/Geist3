// ExpressionChecker+Effects.swift — effect-tree walking and single-expression
// checks for ExpressionChecker, split out of the primary struct to stay within
// the type_body_length lint limit.

import CardExpr
import Foundation

extension ExpressionChecker {
    // MARK: effect trees

    /// Walks an effect list, checking each effect; returns the lambda
    /// environment after the list (for code that follows it, like score
    /// choices).
    @discardableResult
    mutating func checkEffects(
        _ effects: [Effect], pointer: String, lambdas: [String: ExprType]
    ) -> [String: ExprType] {
        var lambdas = lambdas
        for (i, effect) in effects.enumerated() {
            let p = "\(pointer)/\(i)"
            switch effect {
            case .set(let path, let to, _):
                checkWrite(path: path, value: to, pointer: "\(p)/set", lambdas: lambdas)
            case .add(let path, let value, _, _):
                checkWrite(path: path, value: value, pointer: "\(p)/add", lambdas: lambdas)
            case .letBinding(let name, let be, _):
                let type = check(
                    be, pointer: "\(p)/let", expected: nil,
                    scope: Scope(lambdas: lambdas))
                if let type {
                    lambdas[name] = type
                    collectedLets[name] = type
                }
            case .ifElse(let condition, let then, let elseBranch, _):
                check(
                    condition, pointer: "\(p)/if", expected: .bool,
                    scope: Scope(lambdas: lambdas))
                checkEffects(then, pointer: "\(p)/if/then", lambdas: lambdas)
                checkEffects(elseBranch ?? [], pointer: "\(p)/if/else", lambdas: lambdas)
            case .forEach(let kind, let body, _):
                let elementType: ExprType
                switch kind {
                case "seat": elementType = .seat
                case "team": elementType = .team
                default:
                    issues.append(
                        ValidationIssue(
                            .error, "reference/bad-vocabulary", "\(p)/forEach",
                            "'\(kind)' is not an iteration kind. Use 'seat' or 'team'."))
                    elementType = .seat
                }
                var withLambda = lambdas
                withLambda[kind] = elementType
                checkEffects(body, pointer: "\(p)/forEach", lambdas: withLambda)
            case .move(let spec, _):
                if case .expr(let e) = spec.cards {
                    check(
                        e, pointer: "\(p)/move/cards", expected: .list(.card),
                        scope: Scope(lambdas: lambdas))
                }
                expr(spec.toSeat, "\(p)/move/toSeat", .seat, lambdas)
                expr(spec.toTeam, "\(p)/move/toTeam", .team, lambdas)
            case .reveal(_, let seat, _, _):
                expr(seat, "\(p)/reveal/seat", .seat, lambdas)
            case .emit: break
            }
        }
        return lambdas
    }

    mutating func expr(
        _ expr: Expr?, _ pointer: String, _ expected: ExprType?, _ lambdas: [String: ExprType]
    ) {
        check(expr, pointer: pointer, expected: expected, scope: Scope(lambdas: lambdas))
    }

    /// Type-checks one variable write and records the target for stage F.
    mutating func checkWrite(
        path: String, value: Expr, pointer: String, lambdas: [String: ExprType]
    ) {
        guard let parsed = RulesetValidator.parseWritePath(path) else {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' is not a variable path like 'match.score[seat]'."))
            return
        }
        writtenVars.insert("\(parsed.root).\(parsed.name)")
        guard let binding = names.vars[parsed.name] else {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' writes variable '\(parsed.name)', which the ruleset does not "
                        + "declare. Add it under 'vars' or fix the spelling."))
            return
        }
        let rootStore: VarStore = parsed.root == "match" ? .match : .deal
        if binding.scope.store != rootStore {
            issues.append(
                ValidationIssue(
                    .error, "reference/unknown-var", pointer,
                    "'\(path)' reaches a \(parsed.root)-scoped variable, but '\(parsed.name)' is "
                        + "declared with scope '\(names.varScopeSpelling[parsed.name] ?? "?")'."))
        }
        let scope = Scope(lambdas: lambdas)
        if let index = parsed.index {
            let expected: ExprType
            switch binding.scope {
            case .seatMatch, .seatDeal: expected = .seat
            case .teamMatch, .teamDeal: expected = .team
            default:
                issues.append(
                    ValidationIssue(
                        .error, "type/type-mismatch", pointer,
                        "'\(parsed.name)' is not seat- or team-scoped, so '\(path)' cannot "
                            + "take an index. Write '\(parsed.root).\(parsed.name)' instead."))
                expected = .seat
            }
            check(Expr(source: index), pointer: "\(pointer)/index", expected: expected, scope: scope)
        }
        check(value, pointer: "\(pointer)/to", expected: binding.type, scope: scope)
    }

    // MARK: single expression

    @discardableResult
    mutating func check(
        _ expr: Expr?, pointer: String, expected: ExprType?, scope: Scope
    ) -> ExprType? {
        guard let expr else { return nil }
        let parsed: ParsedExpression
        do {
            parsed = try Parser().parse(expr.source)
        } catch let error as ParseError {
            issues.append(
                ValidationIssue(
                    .error, "type/parse-error", pointer,
                    "This expression does not parse: \(plain(error.description)) "
                        + "CardExpr uses single quotes for text, like 'hearts'."))
            return nil
        } catch {
            issues.append(ValidationIssue(.error, "type/parse-error", pointer, "\(error)"))
            return nil
        }
        if parsed.nodeCount > Limits.maxASTNodes {
            issues.append(
                ValidationIssue(
                    .error, "limits/expression-size", pointer,
                    "This expression is \(parsed.nodeCount) AST nodes; the limit is "
                        + "\(Limits.maxASTNodes). Move work into a def."))
        }
        var checker = TypeChecker(context: buildContextSnapshot())
        do {
            let typed = try checker.check(parsed.ast, in: scope)
            if let expected, checker.unify(expected, typed.type) == nil {
                issues.append(
                    ValidationIssue(
                        .error, "type/type-mismatch", pointer,
                        "This expression must produce \(typeDisplay(expected)) but produces "
                            + "\(typeDisplay(typed.type))."))
            }
            return typed.type
        } catch let error as TypeError {
            issues.append(
                ValidationIssue(
                    .error, "type/expression-error", pointer,
                    "\(plain(error.message))"))
            return nil
        } catch {
            issues.append(ValidationIssue(.error, "type/expression-error", pointer, "\(error)"))
            return nil
        }
    }
}
