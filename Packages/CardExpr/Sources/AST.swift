/// A CardExpr abstract syntax tree.
///
/// Every node carries the source span of the sub-expression it covers.
/// Parenthesized groups are not nodes: they are syntactic grouping and do
/// not affect the §11.3 node count.
public indirect enum AST: Sendable {
    case int(Int64, SourceSpan)
    case string(String, SourceSpan)
    case bool(Bool, SourceSpan)
    case null(SourceSpan)
    case ident(String, SourceSpan)
    case list([AST], SourceSpan)
    case unary(Operator, AST, SourceSpan)
    case binary(Operator, AST, AST, SourceSpan)
    case ternary(AST, AST, AST, SourceSpan)
    case member(AST, String, SourceSpan)
    case index(AST, AST, SourceSpan)
    case call(AST, [AST], SourceSpan)

    /// Operators of the expression language.
    public enum Operator: Sendable, Hashable {
        case not
        case negate
        case or
        case and
        case eq
        case neq
        case lt
        case le
        case gt
        case ge
        case inOp
        case add
        case sub
        case mul
        case div
        case mod

        /// The operator's source symbol.
        public var symbol: String {
            switch self {
            case .not: "!"
            case .negate: "-"
            case .or: "||"
            case .and: "&&"
            case .eq: "=="
            case .neq: "!="
            case .lt: "<"
            case .le: "<="
            case .gt: ">"
            case .ge: ">="
            case .inOp: "in"
            case .add: "+"
            case .sub: "-"
            case .mul: "*"
            case .div: "/"
            case .mod: "%"
            }
        }

        /// Precedence level (higher binds tighter).
        public var precedence: Int {
            switch self {
            case .or: 2
            case .and: 3
            case .eq, .neq: 4
            case .lt, .le, .gt, .ge, .inOp: 5
            case .add, .sub: 6
            case .mul, .div, .mod: 7
            case .not, .negate: 8
            }
        }
    }

    /// The source span this node covers.
    public var span: SourceSpan {
        switch self {
        case .int(_, let s), .string(_, let s), .bool(_, let s), .null(let s), .ident(_, let s),
            .list(_, let s), .unary(_, _, let s), .binary(_, _, _, let s),
            .ternary(_, _, _, let s), .member(_, _, let s), .index(_, _, let s),
            .call(_, _, let s):
            s
        }
    }

    /// Precedence level of this node, used for canonical printing.
    public var precedence: Int {
        switch self {
        case .ternary: 1
        case .binary(let op, _, _, _): op.precedence
        case .unary: 8
        default: 8
        }
    }

    /// Canonical, unambiguous re-printing of the expression.
    ///
    /// Parsing `canonical` always yields an AST with the same canonical
    /// form (round-trip property).
    public var canonical: String {
        switch self {
        case .int(let value, _):
            return String(value)
        case .string(let s, _):
            return "'\(s)'"
        case .bool(let flag, _):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .ident(let name, _):
            return name
        case .list(let items, _):
            return "[" + items.map(\.canonical).joined(separator: ", ") + "]"
        case .unary(let op, let operand, _):
            let s = operand.canonical
            return operand.precedence < 8 ? "\(op.symbol)(\(s))" : "\(op.symbol)\(s)"
        case .binary(let op, let lhs, let rhs, _):
            let level = op.precedence
            let left = lhs.canonical
            let right = rhs.canonical
            let lPart = lhs.precedence < level ? "(\(left))" : left
            let rPart = rhs.precedence <= level ? "(\(right))" : right
            return "\(lPart) \(op.symbol) \(rPart)"
        case .ternary(let cond, let then, let els, _):
            let condition = cond.canonical
            let cPart = cond.precedence <= 1 ? "(\(condition))" : condition
            return "\(cPart) ? \(then.canonical) : \(els.canonical)"
        case .member(let base, let name, _):
            let text = base.canonical
            let bPart = base.precedence < 8 ? "(\(text))" : text
            return "\(bPart).\(name)"
        case .index(let base, let idx, _):
            let text = base.canonical
            let bPart = base.precedence < 8 ? "(\(text))" : text
            return "\(bPart)[\(idx.canonical)]"
        case .call(let callee, let args, _):
            let calleeText = callee.canonical
            let cPart = callee.precedence < 8 ? "(\(calleeText))" : calleeText
            return "\(cPart)(\(args.map(\.canonical).joined(separator: ", ")))"
        }
    }

    /// Number of AST nodes in this subtree (this node included). Iterative
    /// with an explicit stack so that long chains — and any deep tree a
    /// caller may hand in — cannot overflow the thread's call stack.
    public var nodeCount: Int {
        var total = 0
        var pending: [AST] = [self]
        while let node = pending.popLast() {
            total += 1
            switch node {
            case .int, .string, .bool, .null, .ident:
                break
            case .list(let items, _):
                pending.append(contentsOf: items)
            case .unary(_, let operand, _):
                pending.append(operand)
            case .binary(_, let lhs, let rhs, _):
                pending.append(lhs)
                pending.append(rhs)
            case .ternary(let cond, let then, let els, _):
                pending.append(cond)
                pending.append(then)
                pending.append(els)
            case .member(let base, _, _):
                pending.append(base)
            case .index(let base, let idx, _):
                pending.append(base)
                pending.append(idx)
            case .call(let callee, let args, _):
                pending.append(callee)
                pending.append(contentsOf: args)
            }
        }
        return total
    }
}
