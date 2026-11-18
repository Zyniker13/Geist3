import CardExpr
import RulesetKit
import Testing

/// Helpers shared by the type-checker tests.
enum Check {
    /// Parses and checks an expression, returning its typed form.
    static func apply(
        _ source: String,
        evaluation: TypeContext.EvaluationContext = .host,
        configure: (inout TypeContext) -> Void = { _ in }
    ) throws -> TypedExpr {
        var context = TypeContext(evaluation: evaluation)
        configure(&context)
        var checker = TypeChecker(context: context)
        return try checker.check(try Parser().parse(source).ast)
    }

    /// Parses and checks an expression, returning the type-error message.
    /// Fails the enclosing test when the expression is accepted.
    static func rejected(
        _ source: String,
        evaluation: TypeContext.EvaluationContext = .host,
        configure: (inout TypeContext) -> Void = { _ in }
    ) -> String {
        do {
            _ = try apply(source, evaluation: evaluation, configure: configure)
        } catch let error as TypeError {
            return error.message
        } catch {
            return "unexpected non-type error: \(error)"
        }
        Issue.record("expected '\(source)' to be rejected")
        return ""
    }

    /// A configure block declaring `hand` (public), `hidden` (none), and
    /// `pile` (owner) zones, layered on top of `extra`.
    static func zones(
        _ extra: @escaping (inout TypeContext) -> Void = { _ in }
    ) -> (inout TypeContext) -> Void {
        { context in
            context.zones["hand"] = ZoneInfo(id: "hand", visibility: .publicZone)
            context.zones["hidden"] = ZoneInfo(id: "hidden", visibility: .none)
            context.zones["pile"] = ZoneInfo(id: "pile", visibility: .owner)
            extra(&context)
        }
    }

    /// Parses and type-checks a def body against its signature text.
    static func def(
        _ signature: String,
        body: String,
        evaluation: TypeContext.EvaluationContext = .host,
        configure: (inout TypeContext) -> Void = { _ in }
    ) throws -> TypedExpr {
        var context = TypeContext(evaluation: evaluation)
        configure(&context)
        let header = try RulesetTypeNames.parseDefSignature(signature, records: context.records)
        var checker = TypeChecker(context: context)
        return try checker.checkDef(
            DefSignature(
                name: header.name,
                params: header.params,
                types: header.types,
                result: header.result,
                body: try Parser().parse(body).ast
            ))
    }

    /// Checks a def body, returning the type-error message. Fails the
    /// enclosing test when the def is accepted. `configure` runs before
    /// checking, for zones and other context.
    static func rejectedDefs(
        _ signature: String,
        body: String,
        evaluation: TypeContext.EvaluationContext = .host,
        configure: (inout TypeContext) -> Void = { _ in }
    ) -> String {
        do {
            _ = try def(signature, body: body, evaluation: evaluation, configure: configure)
        } catch let error as TypeError {
            return error.message
        } catch {
            return "unexpected non-type error: \(error)"
        }
        Issue.record("expected def '\(signature)' to be rejected")
        return ""
    }
}
