import CardExpr

/// The tree-walking evaluator over `Value` (ARCHITECTURE.md §7.4/§7.6).
///
/// Evaluation is deterministic, fuel-metered (each AST node costs 1,
/// each macro element 1 plus its body), and faults instead of hanging:
/// fuel exhaustion, integer overflow, division by zero, `null`
/// dereferences, and out-of-range indexes all raise `EvaluationFault`.
/// Short-circuit operators skip the untaken branch, which is not
/// evaluated and therefore costs no fuel.
public struct Evaluator {
    /// The ruleset context, supplying def bodies.
    public let context: TypeContext

    var fuel: Int
    var pointer: String
    var ruleId: String?
    var env: EvaluationEnvironment
    var lambdaBindings: [String: Value]
    var defParamBindings: [String: Value]
    /// Def bodies checked once and reused across calls in this
    /// evaluation (the check is deterministic, so caching is sound).
    var defBodies: [String: TypedExpr]

    public init(context: TypeContext) {
        self.context = context
        self.fuel = 0
        self.pointer = ""
        self.ruleId = nil
        self.env = EvaluationEnvironment()
        self.lambdaBindings = [:]
        self.defParamBindings = [:]
        self.defBodies = [:]
    }

    /// Evaluates a checked expression and returns its value.
    ///
    /// - Parameters:
    ///   - typed: the expression's typed form from the type checker.
    ///   - env: the evaluation environment (state reads, contextual
    ///     bindings, native implementations).
    ///   - fuel: the evaluation budget; exhausting it is a fault.
    ///   - ruleId: the rule being evaluated, for fault reporting.
    ///   - pointer: the expression's JSON pointer, for fault reporting.
    public mutating func evaluate(
        _ typed: TypedExpr, in env: EvaluationEnvironment, fuel budget: Int = EvaluationFault.expressionBudget,
        ruleId: String? = nil, pointer: String
    ) throws(EvaluationFault) -> Value {
        self.env = env
        self.fuel = budget
        self.ruleId = ruleId
        self.pointer = pointer
        return try walk(typed)
    }

    /// Spends one unit of fuel.
    mutating func spendFuel() throws(EvaluationFault) {
        fuel -= 1
        if fuel < 0 {
            throw EvaluationFault(
                kind: .fuelExhausted, ruleId: ruleId, pointer: pointer,
                message: "expression exceeded its fuel budget"
            )
        }
    }

    /// Faults with the given kind and message.
    /// Raises a fault by throwing; the generic return type lets every
    /// `return try fault(...)` call site type-check in any return context.
    func fault<T>(_ kind: EvaluationFault.Kind, _ message: String) throws(EvaluationFault) -> T {
        throw EvaluationFault(kind: kind, ruleId: ruleId, pointer: pointer, message: message)
    }

    // MARK: Tree walk

    mutating func walk(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        try spendFuel()
        if let value = typed.constant { return value }
        switch typed.node {
        case .int, .string, .bool, .null:
            return walkLiteral(typed)
        case .ident:
            return try evaluateIdent(typed)
        case .list:
            return try evaluateList(typed)
        case .unary(let op, _, _):
            return try evaluateUnary(op, typed)
        case .binary(let op, _, _, _):
            return try evaluateBinary(op, typed)
        case .ternary:
            return try evaluateTernary(typed)
        case .member:
            return try evaluateMember(typed)
        case .index:
            return try evaluateIndex(typed)
        case .call:
            return try evaluateCall(typed)
        }
    }

    /// Literal leaves reform as values when the type checker did not
    /// pre-fold them into `constant`.
    private func walkLiteral(_ typed: TypedExpr) -> Value {
        switch typed.node {
        case .int(let n, _):
            return .int(n)
        case .string(let s, _):
            return .string(s)
        case .bool(let flag, _):
            return .bool(flag)
        default:
            return .null
        }
    }

    mutating func evaluateIdent(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        switch typed.binding {
        case .lambda(let name):
            guard let value = lambdaBindings[name] else {
                return try fault(.unsupportedValue, "internal: lambda '\(name)' is unbound")
            }
            return value
        case .defParam(let name):
            guard let value = defParamBindings[name] else {
                return try fault(.unsupportedValue, "internal: def parameter '\(name)' is unbound")
            }
            return value
        case .contextual(let name):
            guard let value = env.contextual[name] else {
                return try fault(.unsupportedValue, "contextual binding '\(name)' is not bound here")
            }
            return value
        case .none:
            return try fault(.unsupportedValue, "internal: identifier has no binding")
        default:
            return try fault(.unsupportedValue, "internal: unexpected binding on identifier")
        }
    }

    mutating func evaluateList(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        var items: [Value] = []
        items.reserveCapacity(typed.children.count)
        for child in typed.children {
            items.append(try walk(child))
        }
        return .list(items)
    }

    // MARK: Operators

    mutating func evaluateUnary(_ op: AST.Operator, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        var operand = try walk(typed.children[0])
        switch op {
        case .not:
            guard case .bool(let flag) = operand else {
                return try fault(.unsupportedValue, "internal: '!' on non-bool")
            }
            return .bool(!flag)
        case .negate:
            guard case .int(let n) = operand else {
                return try fault(.unsupportedValue, "internal: '-' on non-int")
            }
            let (result, overflow) = n.multipliedReportingOverflow(by: -1)
            if overflow { return try fault(.integerOverflow, "integer overflow in unary '-'") }
            operand = .int(result)
            return operand
        default:
            return try fault(.unsupportedValue, "internal: '\(op.symbol)' is not unary")
        }
    }

    mutating func evaluateBinary(_ op: AST.Operator, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        switch op {
        case .and:
            let lhs = try walk(typed.children[0])
            guard case .bool(let left) = lhs else {
                return try fault(.unsupportedValue, "internal: '&&' on non-bool")
            }
            if !left { return .bool(false) }
            let rhs = try walk(typed.children[1])
            guard case .bool(let right) = rhs else {
                return try fault(.unsupportedValue, "internal: '&&' on non-bool")
            }
            return .bool(right)
        case .or:
            let lhs = try walk(typed.children[0])
            guard case .bool(let left) = lhs else {
                return try fault(.unsupportedValue, "internal: '||' on non-bool")
            }
            if left { return .bool(true) }
            let rhs = try walk(typed.children[1])
            guard case .bool(let right) = rhs else {
                return try fault(.unsupportedValue, "internal: '||' on non-bool")
            }
            return .bool(right)
        default:
            let lhs = try walk(typed.children[0])
            let rhs = try walk(typed.children[1])
            return try strictBinary(op, lhs, rhs)
        }
    }

    /// Binary operators that evaluate both operands.
    mutating func strictBinary(_ op: AST.Operator, _ lhs: Value, _ rhs: Value) throws(EvaluationFault) -> Value {
        switch op {
        case .eq, .neq:
            let equal = lhs == rhs
            return .bool(op == .eq ? equal : !equal)
        case .lt, .le, .gt, .ge:
            return try orderedBinary(op, lhs, rhs)
        case .inOp:
            return .bool(try membership(of: lhs, in: rhs))
        case .add, .sub, .mul, .div, .mod:
            return try arithmeticBinary(op, lhs, rhs)
        default:
            return try fault(.unsupportedValue, "internal: '\(op.symbol)' is not strict")
        }
    }

    /// Ordered comparisons (`<`, `<=`, `>`, `>=`) over int operands.
    mutating func orderedBinary(_ op: AST.Operator, _ lhs: Value, _ rhs: Value) throws(EvaluationFault) -> Value {
        if case .null = lhs { return try fault(.nullDereference, "'\(op.symbol)' dereferences null") }
        if case .null = rhs { return try fault(.nullDereference, "'\(op.symbol)' dereferences null") }
        guard case (.int(let left), .int(let right)) = (lhs, rhs) else {
            return try fault(.unsupportedValue, "internal: '\(op.symbol)' on non-int")
        }
        switch op {
        case .lt: return .bool(left < right)
        case .le: return .bool(left <= right)
        case .gt: return .bool(left > right)
        default: return .bool(left >= right)
        }
    }

    /// Arithmetic operators (`+`, `-`, `*`, `/`, `%`) over int operands.
    mutating func arithmeticBinary(_ op: AST.Operator, _ lhs: Value, _ rhs: Value) throws(EvaluationFault) -> Value {
        if case .null = lhs { return try fault(.nullDereference, "'\(op.symbol)' dereferences null") }
        if case .null = rhs { return try fault(.nullDereference, "'\(op.symbol)' dereferences null") }
        guard case (.int(let left), .int(let right)) = (lhs, rhs) else {
            return try fault(.unsupportedValue, "internal: '\(op.symbol)' on non-int")
        }
        return .int(try checkedArithmetic(op, left, right))
    }

    mutating func checkedArithmetic(
        _ op: AST.Operator, _ left: Int64, _ right: Int64
    ) throws(EvaluationFault) -> Int64 {
        let (result, overflow): (Int64, Bool)
        switch op {
        case .add: (result, overflow) = left.addingReportingOverflow(right)
        case .sub: (result, overflow) = left.subtractingReportingOverflow(right)
        case .mul: (result, overflow) = left.multipliedReportingOverflow(by: right)
        case .div:
            guard right != 0 else { return try fault(.divisionByZero, "division by zero") }
            (result, overflow) = left.dividedReportingOverflow(by: right)
        case .mod:
            guard right != 0 else { return try fault(.divisionByZero, "modulo by zero") }
            (result, overflow) = left.remainderReportingOverflow(dividingBy: right)
        default:
            return try fault(.unsupportedValue, "internal: '\(op.symbol)' is not arithmetic")
        }
        if overflow { return try fault(.integerOverflow, "integer overflow in '\(op.symbol)'") }
        return result
    }

    /// Membership search over nested lists, mirroring the type checker's
    /// §7.2 rule (a card `in hands` is found inside any hand).
    func membership(of value: Value, in list: Value, depth: Int = 0) throws(EvaluationFault) -> Bool {
        guard case .list(let items) = list else {
            return try fault(.unsupportedValue, "internal: 'in' on non-list")
        }
        for item in items where item == value {
            return true
        }
        if depth >= 8 { return false }
        for case .list(let sub) in items
        where try membership(of: value, in: .list(sub), depth: depth + 1) {
            return true
        }
        return false
    }

    mutating func evaluateTernary(_ typed: TypedExpr) throws(EvaluationFault) -> Value {
        let condition = try walk(typed.children[0])
        guard case .bool(let flag) = condition else {
            return try fault(.unsupportedValue, "internal: ternary condition is not bool")
        }
        return try walk(flag ? typed.children[1] : typed.children[2])
    }
}
