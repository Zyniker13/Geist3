// Stage F (§11.4): reachability, termination, and fallback checks over
// the static phase-flow graph.

import CardExpr

// MARK: - Stage F — static analysis

struct StaticAnalysis {
    let doc: RulesetDocument
    let names: NameTables
    /// `match.score`-style roots written by any effect.
    let writtenVars: Set<String>
    var issues: [ValidationIssue] = []

    mutating func run() -> [ValidationIssue] {
        guard let phases = doc.phases, !phases.isEmpty else { return issues }
        var graph = PhaseGraph(phases: phases, phaseIds: names.phaseIds)
        graph.build()

        // Reachability.
        let reachable = graph.reachableFromStart()
        for (i, phase) in phases.enumerated() where !reachable.contains(i) {
            issues.append(
                ValidationIssue(
                    graph.hasDynamicNext ? .warning : .error,
                    "reachability/unreachable-phase", "/phases/\(i)",
                    "Phase '\(phase.id)' can never run: no earlier phase falls through to it or "
                        + "jumps to it. Check the 'next' fields of the phases before it."))
        }

        // Termination: every cycle needs a progress mechanic or an end
        // condition that watches changing state.
        for cycle in graph.cycles() {
            let hasProgress = cycle.contains { Vocab.progressMechanics.contains(phases[$0].mechanic) }
            if !hasProgress {
                let first = cycle.min()!
                if endConditionIsStatic() {
                    issues.append(
                        ValidationIssue(
                            .error, "termination/no-progress", "/phases/\(first)",
                            "The phases \(cyclePhaseNames(cycle, phases)) form a loop where "
                                + "nothing changes: no card moves and no score is written, so the end "
                                + "condition can never fire. Add a phase that changes state, or make "
                                + "the end condition watch a variable that effects write."))
                }
            }
        }
        // The end condition must reference a variable some effect changes.
        if let when = doc.end?.when {
            let read = Self.readVarRoots(when.source)
            let watched = read.filter { writtenVars.contains($0) }
            if watched.isEmpty {
                issues.append(
                    ValidationIssue(
                        .error, "termination/end-var-unchanged", "/end/when",
                        "The end condition reads \(read.sorted().isEmpty ? "no variables" : read.sorted().joined(separator: ", "))"
                            + ", but no effect writes any of them, so it can never become true. "
                            + "Have the scoring phase write one of those variables."))
            }
        } else {
            issues.append(
                ValidationIssue(
                    .warning, "termination/no-end-condition", "/end",
                    "The ruleset has no end condition, so matches only end by the deal cap. "
                        + "Fine for practice games; add 'when' to end matches by score."))
        }

        // Fallback guards: every restrictive guard must carry a valid
        // `otherwise` (the schema requires the field; here we check the value).
        for (i, phase) in phases.enumerated() {
            let p = "/phases/\(i)/params"
            var guards: [(PlayGuard, String)] = []
            if case .trickPlay(let t) = phase.params {
                if let g = t.leadAllowed { guards.append((g, "\(p)/leadAllowed")) }
                if let g = t.playAllowed { guards.append((g, "\(p)/playAllowed")) }
            }
            for (guardSpec, pointer) in guards where !Vocab.otherwiseValues.contains(guardSpec.otherwise) {
                issues.append(
                    ValidationIssue(
                        .error, "fallback/invalid", "\(pointer)/otherwise",
                        "'\(guardSpec.otherwise)' is not a valid fallback. When the guard "
                            + "could empty the legal moves, use 'otherwise': \"any\" so the player "
                            + "can always act."))
            }
        }
        return issues
    }

    func cyclePhaseNames(_ cycle: [Int], _ phases: [Phase]) -> String {
        cycle.sorted().map { "'\(phases[$0].id)'" }.joined(separator: " → ")
    }

    /// Stage F's termination reasoning only holds when the end condition is a
    /// static expression (not a native that could observe anything).
    func endConditionIsStatic() -> Bool { doc.end?.when != nil }

    /// Var roots (match.x / deal.x) an expression reads.
    static func readVarRoots(_ source: String) -> Set<String> {
        var roots: Set<String> = []
        let words = source.split(
            whereSeparator: { !"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.[]()".contains($0) })
        for word in words {
            let text = String(word)
            for prefix in ["match.", "deal."] where text.hasPrefix(prefix) {
                let rest = text.dropFirst(prefix.count)
                let name = rest.prefix { $0 != "[" && $0 != "." && $0 != ")" && $0 != "," }
                if !name.isEmpty { roots.insert("\(prefix.dropLast()).\(name)") }
            }
        }
        return roots
    }
}

// MARK: - Phase graph

/// The static phase-flow graph: an explicit string `next` is an edge;
/// otherwise a phase falls through to the next phase in list order.
struct PhaseGraph {
    let phases: [Phase]
    let phaseIds: Set<String>
    var edges: [Int: [Int]] = [:]
    var hasDynamicNext = false

    init(phases: [Phase], phaseIds: Set<String>) {
        self.phases = phases
        self.phaseIds = phaseIds
    }

    mutating func build() {
        for (i, phase) in phases.enumerated() {
            var targets: [Int] = []
            if let next = phase.next {
                if let target = RulesetValidator.literalStringStatic(next.source),
                    let j = phases.firstIndex(where: { $0.id == target })
                {
                    targets.append(j)
                } else {
                    hasDynamicNext = true
                }
            } else if i + 1 < phases.count {
                targets.append(i + 1)
            }
            edges[i] = targets
        }
    }

    func reachableFromStart() -> Set<Int> {
        guard !phases.isEmpty else { return [] }
        var seen: Set<Int> = [0]
        var queue = [0]
        while let i = queue.popLast() {
            for j in edges[i] ?? [] where !seen.contains(j) {
                seen.insert(j)
                queue.append(j)
            }
        }
        return seen
    }

    /// All cycles, each reported once, as sorted index lists.
    func cycles() -> [[Int]] {
        var cycles: [[Int]] = []
        var state = [Int](repeating: 0, count: phases.count)  // 0 unvisited 1 active 2 done
        func dfs(_ i: Int, _ stack: [Int]) {
            guard state[i] == 0 else {
                if state[i] == 1, let at = stack.firstIndex(of: i) {
                    cycles.append(Array(stack[at...]).sorted())
                }
                return
            }
            state[i] = 1
            for j in edges[i] ?? [] {
                dfs(j, stack + [i])
            }
            state[i] = 2
        }
        for i in phases.indices { dfs(i, []) }
        // Deduplicate cycles that visit the same index set.
        var unique: [[Int]] = []
        var seen: Set<[Int]> = []
        for cycle in cycles where !seen.contains(cycle) {
            seen.insert(cycle)
            unique.append(cycle)
        }
        return unique
    }
}

extension RulesetValidator {
    /// String-literal helper shared with the phase graph.
    static func literalStringStatic(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }
}

extension Array where Element == JSONField {
    func first(key: String) -> JSONField? {
        first { $0.key == key }
    }
}
