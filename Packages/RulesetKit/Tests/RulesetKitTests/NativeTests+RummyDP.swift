// NativeTests+RummyDP.swift — rummy.melds deadwood-DP cross-check against an explicitly enumerated candidate set (P2.4).

import RulesetKit
import Testing

extension NativeTests {
    // MARK: - rummy.melds: deadwood-DP cross-check (10k hands)

    struct RummyConfig {
        let minSet: Int
        let minRun: Int
        let aceHigh: Bool
        let wrap: Bool
        let wildRanks: [String]
    }

    static func rummyOrder(_ aceHigh: Bool) -> [String] {
        var order = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
        if aceHigh {
            order.removeFirst()
            order.append("A")
        }
        return order
    }

    /// Mirror of the native's canonical deck order (ADR-0025): naturals in
    /// (rank order, suit, id) order, then wilds in (suit, id) order.
    static func canonDeck(_ deck: [String], aceHigh: Bool, wild: Set<String>) -> [String] {
        let order = Self.rummyOrder(aceHigh)
        func rankIndex(_ id: String) -> Int {
            order.firstIndex(of: String(id.dropLast())) ?? order.count
        }
        let naturals = deck.filter { !wild.contains(String($0.dropLast())) }
            .sorted { (rankIndex($0), $0.last!, $0) < (rankIndex($1), $1.last!, $1) }
        let wilds = deck.filter { wild.contains(String($0.dropLast())) }
            .sorted { ($0.last!, $0) < ($1.last!, $1) }
        return naturals + wilds
    }

    static func combos(_ xs: [Int], _ k: Int) -> [[Int]] {
        if k == 0 { return [[]] }
        if xs.count < k { return [] }
        var out: [[Int]] = []
        for (i, x) in xs.enumerated() {
            for rest in Self.combos(Array(xs[(i + 1)...]), k - 1) {
                out.append([x] + rest)
            }
        }
        return out
    }

    /// Sets: any 1...count naturals of one rank, padded with wilds up to
    /// minSet and beyond.
    static func setMeldCandidates(
        byRank: [String: [Int]], wildIndices: [Int], rules: RummyConfig
    ) -> Set<Int> {
        var candidates: Set<Int> = []
        for (_, naturals) in byRank {
            for k in 1...naturals.count {
                for naturalChoice in Self.combos(naturals, k) {
                    // Skip when the deck does not carry enough wilds to
                    // pad this rank up to minSet (non-wild configs make
                    // the lower bound exceed wildIndices.count).
                    let minWilds = max(rules.minSet - k, 0)
                    guard wildIndices.count >= minWilds else { continue }
                    for w in minWilds...wildIndices.count {
                        for wildChoice in Self.combos(wildIndices, w) {
                            var mask = 0
                            for i in naturalChoice + wildChoice { mask |= 1 << i }
                            candidates.insert(mask)
                        }
                    }
                }
            }
        }
        return candidates
    }

    /// One window: at least one natural, gaps no more than wilds; emits a
    /// mask per wild choice.
    static func windowMasks(window: [Int], slots: [Int: Int], wildIndices: [Int]) -> [Int] {
        let naturals = window.compactMap { slots[$0] }
        guard !naturals.isEmpty else { return [] }
        let missing = window.count - naturals.count
        guard missing <= wildIndices.count else { return [] }
        var masks: [Int] = []
        for wildChoice in Self.combos(wildIndices, missing) {
            var mask = 0
            for i in naturals + wildChoice { mask |= 1 << i }
            masks.append(mask)
        }
        return masks
    }

    /// Runs: per suit, windows of consecutive ranks (wrapping mod 13 when
    /// allowed), one natural per rank present, wilds in the gaps, length
    /// from minRun up; windows deduplicate by their rank set.
    static func runMeldCandidates(
        bySuit: [Character: [Int: Int]], order: [String],
        wildIndices: [Int], rules: RummyConfig
    ) -> Set<Int> {
        var candidates: Set<Int> = []
        let rankCount = order.count
        for (_, slots) in bySuit {
            var seen: Set<[Int]> = []
            for start in 0..<rankCount {
                var window: [Int] = []
                var cursor = start
                while true {
                    if window.count == rankCount { break }
                    if !rules.wrap && cursor >= rankCount { break }
                    if rules.wrap { cursor = cursor % rankCount }
                    window.append(cursor)
                    cursor += 1
                    let key = window.sorted()
                    guard window.count >= rules.minRun, !seen.contains(key) else { continue }
                    seen.insert(key)
                    for mask in Self.windowMasks(window: window, slots: slots, wildIndices: wildIndices) {
                        candidates.insert(mask)
                    }
                }
            }
        }
        return candidates
    }

    /// Exact-cover DP: lowest unassigned card either stays dead or is
    /// melded away by a candidate containing it.
    static func exactCoverDeadwood(candidates: Set<Int>, pips: [Int]) -> Int {
        let n = pips.count
        let candidateMasks = candidates.sorted()
        var buckets: [[Int]] = .init(repeating: [], count: n)
        for mask in candidateMasks {
            for i in 0..<n where mask & (1 << i) != 0 { buckets[i].append(mask) }
        }
        var best = [Int](repeating: Int.max, count: 1 << n)
        best[0] = 0
        for mask in 1..<(1 << n) {
            let pivot = mask.trailingZeroBitCount
            var value = best[mask ^ (1 << pivot)] + pips[pivot]
            for meld in buckets[pivot] where meld & mask == meld {
                let rest = mask & ~meld
                if best[rest] < value { value = best[rest] }
            }
            best[mask] = value
        }
        return best[(1 << n) - 1]
    }

    /// Reference meld engine: enumerate every legal meld exactly as §5.8
    /// defines them (sets of naturals plus wilds to minSet; per-suit runs
    /// spanning consecutive ranks with wilds in the gaps), then solve the
    /// exact-cover minimum-deadwood problem by subset DP. Completely
    /// independent of the native's memoized search.
    static func referenceMelds(
        _ deck: [String], rules: RummyConfig
    ) -> (optimum: Int, candidates: Set<Int>, pips: [Int]) {
        let wild = Set(rules.wildRanks)
        let ordered = Self.canonDeck(deck, aceHigh: rules.aceHigh, wild: wild)
        let order = Self.rummyOrder(rules.aceHigh)

        func pip(_ id: String) -> Int {
            let rank = String(id.dropLast())
            if wild.contains(rank) { return 0 }
            switch rank {
            case "A": return 1
            case "J", "Q", "K", "10": return 10
            default: return Int(rank)!
            }
        }
        let pips = ordered.map(pip)

        var byRank: [String: [Int]] = [:]
        for (i, id) in ordered.enumerated() {
            let rank = String(id.dropLast())
            if !wild.contains(rank) { byRank[rank, default: []].append(i) }
        }
        let wildIndices = ordered.indices.filter { wild.contains(String(ordered[$0].dropLast())) }

        var bySuit: [Character: [Int: Int]] = [:]
        for (i, id) in ordered.enumerated() {
            let rank = String(id.dropLast())
            if !wild.contains(rank) {
                bySuit[id.last!, default: [:]][order.firstIndex(of: rank)!] = i
            }
        }

        var candidates = Self.setMeldCandidates(byRank: byRank, wildIndices: wildIndices, rules: rules)
        candidates.formUnion(
            Self.runMeldCandidates(bySuit: bySuit, order: order, wildIndices: wildIndices, rules: rules)
        )
        let optimum = Self.exactCoverDeadwood(candidates: candidates, pips: pips)
        return (optimum, candidates, pips)
    }

    /// Structural checks on the native's melds (mapped to canonical deck
    /// indices): each meld sorted, the list lexicographically ordered,
    /// every meld a legal candidate, no overlaps, full coverage with the
    /// dead cards, and the deadwood value equal to the dead cards' pips.
    /// Records an Issue and returns false on the first violation.
    static func checkMeldStructure(
        seed: Int, mapped: [[Int]],
        reference: (optimum: Int, candidates: Set<Int>, pips: [Int]),
        deadwood: Int, n: Int
    ) -> Bool {
        var used = 0
        var previous: [Int]?
        for meld in mapped {
            if meld != meld.sorted() {
                Issue.record("seed \(seed): meld \(meld) not sorted")
                return false
            }
            if let previous, !(previous.lexicographicallyPrecedes(meld) || previous == meld) {
                Issue.record("seed \(seed): melds not lexicographically ordered: \(previous) then \(meld)")
                return false
            }
            previous = meld
            var mask = 0
            for i in meld { mask |= 1 << i }
            if !reference.candidates.contains(mask) {
                Issue.record("seed \(seed): meld \(meld) is not a legal candidate")
                return false
            }
            if used & mask != 0 {
                Issue.record("seed \(seed): meld \(meld) overlaps an earlier meld")
                return false
            }
            used |= mask
        }
        var deadMask = 0
        for i in 0..<n where used & (1 << i) == 0 { deadMask |= 1 << i }
        if used | deadMask != (1 << n) - 1 {
            Issue.record("seed \(seed): melds and deadwood do not cover the hand")
            return false
        }
        var deadSum = 0
        for i in 0..<n where deadMask & (1 << i) != 0 { deadSum += reference.pips[i] }
        if deadSum != deadwood {
            Issue.record("seed \(seed): deadwood sum \(deadSum) ≠ reported \(deadwood)")
            return false
        }
        return true
    }

    @Test func meldsMatchReferenceDP() throws {
        let configs: [RummyConfig] = [
            RummyConfig(minSet: 3, minRun: 3, aceHigh: false, wrap: false, wildRanks: []),
            RummyConfig(minSet: 3, minRun: 3, aceHigh: true, wrap: false, wildRanks: []),
            RummyConfig(minSet: 3, minRun: 3, aceHigh: false, wrap: true, wildRanks: []),
            RummyConfig(minSet: 3, minRun: 3, aceHigh: true, wrap: true, wildRanks: []),
            RummyConfig(minSet: 3, minRun: 4, aceHigh: false, wrap: false, wildRanks: ["2"]),
            RummyConfig(minSet: 3, minRun: 3, aceHigh: true, wrap: false, wildRanks: ["7"]),
        ]

        for seed in 1...10_000 {
            let size = seed <= 5_000 ? 10 : 11
            let config = configs[(seed - 1) % configs.count]
            let dealt = Self.lcgDeal(seed: UInt64(seed), deck: Self.deck52, take: size)
            let rules = Self.rummyRules(
                minSet: config.minSet, minRun: config.minRun,
                aceHigh: config.aceHigh, wrap: config.wrap,
                wildRanks: config.wildRanks
            )
            let reference = Self.referenceMelds(dealt, rules: config)
            let result = try Self.call("rummy.melds", [Self.cards(dealt), rules])
            let parts = Self.meldParts(result)

            if parts.deadwood != reference.optimum {
                let context = "seed \(seed) config \((seed - 1) % configs.count) \(dealt)"
                Issue.record("\(context): native deadwood \(parts.deadwood), reference \(reference.optimum)")
                return
            }

            // Map the native's card ids back to canonical deck indices so
            // the structural checks below compare against the reference's
            // index-space candidates.
            let canon = Self.canonDeck(dealt, aceHigh: config.aceHigh, wild: Set(config.wildRanks))
            let indexOf = Dictionary(uniqueKeysWithValues: canon.enumerated().map { ($1, $0) })
            var mapped: [[Int]] = []
            var unknownId = false
            for ids in parts.melds {
                var indices: [Int] = []
                for id in ids {
                    guard let index = indexOf[id] else {
                        Issue.record("seed \(seed): unknown card id \(id)")
                        unknownId = true
                        break
                    }
                    indices.append(index)
                }
                mapped.append(indices)
            }
            if unknownId { return }
            if !Self.checkMeldStructure(
                seed: seed, mapped: mapped, reference: reference,
                deadwood: parts.deadwood, n: dealt.count
            ) {
                return
            }
        }
    }

}
