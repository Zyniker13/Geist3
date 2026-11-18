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
        case .int(let v, _):
            return String(v)
        case .string(let s, _):
            return "'\(s)'"
        case .bool(let b, _):
            return b ? "true" : "false"
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
            let p = op.precedence
            let l = lhs.canonical
            let r = rhs.canonical
            let lPart = lhs.precedence < p ? "(\(l))" : l
            let rPart = rhs.precedence <= p ? "(\(r))" : r
            return "\(lPart) \(op.symbol) \(rPart)"
        case .ternary(let cond, let then, let els, _):
            let c = cond.canonical
            let cPart = cond.precedence <= 1 ? "(\(c))" : c
            return "\(cPart) ? \(then.canonical) : \(els.canonical)"
        case .member(let base, let name, _):
            let b = base.canonical
            let bPart = base.precedence < 8 ? "(\(b))" : b
            return "\(bPart).\(name)"
        case .index(let base, let idx, _):
            let b = base.canonical
            let bPart = base.precedence < 8 ? "(\(b))" : b
            return "\(bPart)[\(idx.canonical)]"
        case .call(let callee, let args, _):
            let c = callee.canonical
            let cPart = callee.precedence < 8 ? "(\(c))" : c
            return "\(cPart)(\(args.map(\.canonical).joined(separator: ", ")))"
        }
    }

    /// Number of AST nodes in this subtree (this node included).
    public var nodeCount: Int {
        switch self {
        case .int, .string, .bool, .null, .ident:
            return 1
        case .list(let items, _):
            return 1 + items.reduce(0) { $0 + $1.nodeCount }
        case .unary(_, let operand, _):
            return 1 + operand.nodeCount
        case .binary(_, let lhs, let rhs, _):
            return 1 + lhs.nodeCount + rhs.nodeCount
        case .ternary(let cond, let then, let els, _):
            return 1 + cond.nodeCount + then.nodeCount + els.nodeCount
        case .member(let base, _, _):
            return 1 + base.nodeCount
        case .index(let base, let idx, _):
            return 1 + base.nodeCount + idx.nodeCount
        case .call(let callee, let args, _):
            return 1 + callee.nodeCount + args.reduce(0) { $0 + $1.nodeCount }
        }
    }
}
