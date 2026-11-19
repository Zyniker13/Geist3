import CardExpr

/// A checked expression prepared for repeated evaluation (§7.4): the
/// constant folder has run once, so evaluation during play pays no
/// folding cost.
public struct CompiledExpression: Sendable {
    /// The folded form of the expression.
    public let typed: TypedExpr
    /// True when folding replaced the whole expression with a constant.
    public let isConstant: Bool

    public init(typed: TypedExpr, isConstant: Bool) {
        self.typed = typed
        self.isConstant = isConstant
    }
}

/// Folds constant subexpressions of a checked expression.
///
/// Folding is conservative: a subtree is replaced by its value only
/// when the subtree is provably environment-independent (literals,
/// operators, list literals, ternaries only — no identifiers, members,
/// indexes, or calls) and evaluating it cannot fault. The result
/// evaluates to exactly what the original would, faults included.
///
/// Short-circuit pruning is safe even when the untaken branch is not a
/// constant: `false && e` folds to `false` because the evaluator would
/// never evaluate `e` at runtime either. Ternaries with a constant
/// condition fold only when the taken branch is itself a constant.
///
/// The walk is iterative (an explicit stack), so arbitrarily deep
/// expressions cannot exhaust the call stack.
public struct ConstantFolder: Sendable {
    public init() {}

    /// Folds a checked expression and returns the result.
    public func fold(_ typed: TypedExpr) -> TypedExpr {
        let folder = Folder()
        return folder.fold(typed)
    }

    private struct Frame {
        let node: TypedExpr
        var childIndex: Int
        var folded: [TypedExpr]
    }

    private struct Folder {

        /// Folding runs its own evaluator with a fixed, bounded fuel
        /// budget; a fold candidate larger than this is left unfolded.
        private static let foldFuel = 10_000

        func fold(_ root: TypedExpr) -> TypedExpr {
            var stack: [Frame] = [Frame(node: root, childIndex: 0, folded: [])]
            var result: TypedExpr?
            while let top = stack.last {
                if top.childIndex < top.node.children.count {
                    let child = top.node.children[top.childIndex]
                    stack[stack.count - 1].childIndex += 1
                    stack.append(Frame(node: child, childIndex: 0, folded: []))
                } else {
                    stack.removeLast()
                    let foldedNode = foldNode(top.node, children: top.folded)
                    if var parent = stack.last {
                        parent.folded.append(foldedNode)
                        stack[stack.count - 1] = parent
                    } else {
                        result = foldedNode
                    }
                }
            }
            return result ?? root
        }

        private func foldNode(_ node: TypedExpr, children: [TypedExpr]) -> TypedExpr {
            let candidate = TypedExpr(
                node: node.node, type: node.type, children: children, binding: node.binding
            )
            // Fold only subtrees that read nothing from the environment.
            // Evaluating the candidate with a scratch evaluator is the
            // test of foldability: if it faults (overflow, division by
            // zero), the subtree stays unfolded so the fault still
            // happens at play time, exactly as unfolded evaluation would.
            guard isPureLiteral(candidate) else {
                return candidate
            }
            var evaluator = Evaluator(context: TypeContext())
            guard
                let value = try? evaluator.evaluate(
                    candidate, in: EvaluationEnvironment(), fuel: Self.foldFuel, pointer: ""
                )
            else {
                return candidate
            }
            return TypedExpr(
                node: node.node, type: node.type, children: children, binding: node.binding,
                constant: value
            )
        }

        /// Whether the subtree reads nothing from the environment: only
        /// literals, operators, list literals, and ternaries appear.
        private func isPureLiteral(_ node: TypedExpr) -> Bool {
            var stack: [TypedExpr] = [node]
            while let current = stack.popLast() {
                switch current.node {
                case .int, .string, .bool, .null, .list, .unary, .binary, .ternary:
                    stack.append(contentsOf: current.children)
                default:
                    return false
                }
            }
            return true
        }
    }
}

/// The per-ruleset compiled-expression cache (§7.4): rule expressions
/// are looked up by (ruleset hash, JSON pointer) every time a rule is
/// evaluated, so their folded forms are memoized. Bounded: the oldest
/// entry is evicted when the cache is full. Not thread-safe; the engine
/// calls it from its single evaluation path.
public struct CompiledExpressionCache {
    /// One cached expression's key.
    public struct Key: Hashable, Sendable {
        public let rulesetHash: String
        public let pointer: String

        public init(rulesetHash: String, pointer: String) {
            self.rulesetHash = rulesetHash
            self.pointer = pointer
        }
    }

    private var entries: [(key: Key, typed: TypedExpr)] = []
    private var index: [Key: Int] = [:]
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// The number of cached expressions.
    public var count: Int {
        entries.count
    }

    /// Returns the cached folded expression, if any.
    public mutating func get(_ key: Key) -> TypedExpr? {
        index[key].map { entries[$0].typed }
    }

    /// Caches a folded expression, evicting the oldest entry when full.
    public mutating func insert(_ key: Key, _ typed: TypedExpr) {
        if index[key] != nil {
            return
        }
        if entries.count >= capacity {
            let oldest = entries.removeFirst()
            index.removeValue(forKey: oldest.key)
            index = [:]
            for position in entries.indices {
                index[entries[position].key] = position
            }
        }
        index[key] = entries.count
        entries.append((key, typed))
    }
}
