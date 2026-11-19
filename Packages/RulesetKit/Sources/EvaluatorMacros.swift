import CardExpr

/// The collection macros of the expression language (§7.1): the
/// aggregates, membership, and lambda macros, evaluated against the
/// environment. All macros are pure over the environment: the same
/// environment and arguments always produce the same value.
extension Evaluator {
    // MARK: Collection macros (§7.1)

    mutating func evaluateMacro(_ macro: MacroID, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        let receiver = try walk(typed.children[0])
        guard case .list(let items) = receiver else {
            return try fault(.unsupportedValue, "internal: macro receiver is not a list")
        }
        if macro.lambda {
            let body = typed.children.count > 1 ? typed.children[1] : nil
            return try evaluateLambdaMacro(macro, items, body: body, typed: typed)
        }
        switch macro {
        case .sum:
            return try sumElements(items)
        case .min, .max:
            return try minMaxElement(macro, items)
        case .size:
            return .int(Int64(items.count))
        case .first:
            return items.first ?? .null
        case .contains:
            return try containsElement(items, needle: typed.children.count > 1 ? typed.children[1] : nil)
        case .map, .filter, .exists, .all, .count, .sortBy:
            return try fault(.unsupportedValue, "internal: unexpected lambda macro case")
        }
    }

    /// `.sum()`: fold a list of ints with overflow checking.
    private mutating func sumElements(_ items: [Value]) throws(EvaluationFault) -> Value {
        var total: Int64 = 0
        for element in items {
            try spendFuel()
            guard case .int(let n) = element else {
                return try fault(.unsupportedValue, "internal: '.sum()' element is not an int")
            }
            let (sum, overflow) = total.addingReportingOverflow(n)
            if overflow {
                return try fault(.integerOverflow, "integer overflow in '.sum()'")
            }
            total = sum
        }
        return .int(total)
    }

    private mutating func evaluateLambdaMacro(
        _ macro: MacroID, _ items: [Value], body: TypedExpr?, typed: TypedExpr
    ) throws(EvaluationFault) -> Value {
        guard let body = body else {
            return try fault(.unsupportedValue, "internal: lambda macro has no body")
        }
        let name = macroLambdaName(typed)
        let previous = name.flatMap { lambdaBindings[$0] }
        defer {
            if let name = name {
                lambdaBindings[name] = previous
            }
        }
        switch macro {
        case .map:
            return try mapElements(items, name: name, body: body)
        case .filter:
            return try filterElements(items, name: name, body: body)
        case .exists:
            return try existsElement(items, name: name, body: body)
        case .all:
            return try allElements(items, name: name, body: body)
        case .count:
            return try countMatches(items, name: name, body: body)
        case .sortBy:
            return try sortByKeys(items, name: name, body: body)
        case .sum, .min, .max, .size, .first, .contains:
            return try fault(.unsupportedValue, "internal: unexpected plain macro case")
        }
    }

    /// `.map(lambda)`: apply the lambda to every element.
    private mutating func mapElements(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        var results: [Value] = []
        results.reserveCapacity(items.count)
        for element in items {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            results.append(try walk(body))
        }
        return .list(results)
    }

    /// `.filter(lambda)`: keep the elements the lambda accepts.
    private mutating func filterElements(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        var results: [Value] = []
        for element in items {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            guard case .bool(let keep) = try walk(body) else {
                return try fault(.unsupportedValue, "internal: filter body is not bool")
            }
            if keep {
                results.append(element)
            }
        }
        return .list(results)
    }

    /// `.exists(lambda)`: whether the lambda accepts any element.
    private mutating func existsElement(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        for element in items {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            guard case .bool(let hit) = try walk(body) else {
                return try fault(.unsupportedValue, "internal: exists body is not bool")
            }
            if hit {
                return .bool(true)
            }
        }
        return .bool(false)
    }

    /// `.all(lambda)`: whether the lambda accepts every element.
    private mutating func allElements(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        for element in items {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            guard case .bool(let pass) = try walk(body) else {
                return try fault(.unsupportedValue, "internal: all body is not bool")
            }
            if !pass {
                return .bool(false)
            }
        }
        return .bool(true)
    }

    /// `.count(lambda)`: how many elements the lambda accepts.
    private mutating func countMatches(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        var matches = 0
        for element in items {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            guard case .bool(let hit) = try walk(body) else {
                return try fault(.unsupportedValue, "internal: count body is not bool")
            }
            if hit {
                matches += 1
            }
        }
        return .int(Int64(matches))
    }

    /// The lambda's parameter name, recovered from the source call's
    /// first argument (the checker's typed body alone does not carry it).
    private func macroLambdaName(_ typed: TypedExpr) -> String? {
        guard case .call(let callee, let sourceArgs, _) = typed.node else { return nil }
        guard case .member = callee, let first = sourceArgs.first else { return nil }
        guard case .ident(let name, _) = first else { return nil }
        return name
    }

    /// Sorts by the lambda's key with a stable tiebreak on position:
    /// equal keys keep their source order.
    private mutating func sortByKeys(
        _ items: [Value], name: String?, body: TypedExpr
    ) throws(EvaluationFault) -> Value {
        var keyed: [(key: SortKey, index: Int, item: Value)] = []
        keyed.reserveCapacity(items.count)
        let previous = name.flatMap { lambdaBindings[$0] }
        defer {
            if let name = name {
                lambdaBindings[name] = previous
            }
        }
        for (index, element) in items.enumerated() {
            try spendFuel()
            if let name = name {
                lambdaBindings[name] = element
            }
            keyed.append((try sortKey(try walk(body)), index, element))
        }
        keyed.sort { first, second in
            if first.key == second.key {
                return first.index < second.index
            }
            return compareKeys(first.key, second.key)
        }
        return .list(keyed.map { $0.item })
    }

    private mutating func minMaxElement(_ macro: MacroID, _ items: [Value]) throws(EvaluationFault) -> Value {
        var best: Value?
        for element in items {
            try spendFuel()
            switch (element, best) {
            case (.int(let n), nil):
                best = .int(n)
            case (.int(let n), .int(let running)?):
                if macro == .min ? n < running : n > running {
                    best = .int(n)
                }
            case (.string(let s), nil):
                best = .string(s)
            case (.string(let s), .string(let running)?):
                if macro == .min ? s < running : s > running {
                    best = .string(s)
                }
            default:
                return try fault(
                    .unsupportedValue,
                    "internal: '\(macro.rawValue)' over mixed or non-comparable elements"
                )
            }
        }
        return best ?? .null
    }

    /// Scans for the needle (evaluated once); one fuel unit per element
    /// examined, stopping at the first hit.
    private mutating func containsElement(_ items: [Value], needle: TypedExpr?) throws(EvaluationFault) -> Value {
        guard let needle = needle else {
            return try fault(.unsupportedValue, "internal: contains has no needle")
        }
        let wanted = try walk(needle)
        for element in items {
            try spendFuel()
            if element == wanted {
                return .bool(true)
            }
        }
        return .bool(false)
    }
}

/// A sort key restricted to the comparable value kinds (ints and
/// strings, per the checker's overload set).
enum SortKey: Equatable, Sendable {
    case int(Int64)
    case string(String)
}

private func sortKey(_ value: Value) throws(EvaluationFault) -> SortKey {
    switch value {
    case .int(let n):
        return .int(n)
    case .string(let s):
        return .string(s)
    default:
        throw EvaluationFault(
            kind: .unsupportedValue, ruleId: nil, pointer: "",
            message: "internal: sort key is not an int or string"
        )
    }
}

private func compareKeys(_ first: SortKey, _ second: SortKey) -> Bool {
    switch (first, second) {
    case (.int(let x), .int(let y)):
        return x < y
    case (.string(let x), .string(let y)):
        return x < y
    default:
        return false
    }
}
