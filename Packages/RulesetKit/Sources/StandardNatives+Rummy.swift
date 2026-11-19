// Rummy natives (P2.4): optimal meld finding.

extension StandardNatives {

    // MARK: - rummy.melds(cards, rules)

    /// Optimal meld finding (§5.3): sets of `minSet`+ cards of one rank and
    /// runs of `minRun`+ consecutive same-suit ranks (ace low or high per
    /// the rules record, circular with `wrap`), wild ranks standing for any
    /// card. Returns the partition with the least deadwood that the
    /// deterministic search reaches first.
    static let rummyMelds: Impl = { args in
        let call = "rummy.melds"
        guard args.count == 2 else { try fault(call, "expected 2 arguments") }
        let cards = try cardListArg(args[0], "cards", call)
        let rules = try recordArg(args[1], "rummy.rules", call)
        let minSet = try intArg(try recordField(rules, "minSet", call), "minSet", call)
        let minRun = try intArg(try recordField(rules, "minRun", call), "minRun", call)
        let aceHigh = try boolArg(try recordField(rules, "aceHigh", call), "aceHigh", call)
        let wrap = try boolArg(try recordField(rules, "wrap", call), "wrap", call)
        guard case .list(let wildValues) = try recordField(rules, "wildRanks", call) else {
            try fault(call, "wildRanks must be a list of strings")
        }
        var wildRanks: Set<String> = []
        for wild in wildValues {
            wildRanks.insert(try stringArg(wild, "wildRanks entry", call))
        }
        guard (3...13).contains(minSet), (3...13).contains(minRun) else {
            try fault(call, "minSet/minRun must be between 3 and 13")
        }
        guard cards.count <= 17 else {
            try fault(call, "meld search supports at most 17 cards, got \(cards.count)")
        }

        // Duplicate ids make the partition ambiguous; refuse them.
        var seenIDs = Set<String>()
        for card in cards {
            guard let id = card.cardID, !seenIDs.contains(id) else {
                try fault(call, "cards must have unique ids")
            }
            seenIDs.insert(id)
        }

        var order = frenchRanks
        if aceHigh {
            order.removeFirst()
            order.append("A")
        }
        var rankIndex: [String: Int] = [:]
        for (index, rank) in order.enumerated() { rankIndex[rank] = index }
        for card in cards {
            let rank = card.cardRank ?? ""
            if !wildRanks.contains(rank) && rankIndex[rank] == nil {
                try fault(call, "card of rank '\(rank)' is neither orderable nor wild")
            }
        }

        // A meld is a set of indices into the canonically sorted deck:
        // naturals in (rank order, suit, id) order, then wilds.
        struct Item {
            let card: Value
            let isWild: Bool
            let orderIdx: Int
        }
        let sorted = cards.map { card -> Item in
            let rank = card.cardRank ?? ""
            let isWild = wildRanks.contains(rank)
            let orderIdx = isWild ? order.count : (rankIndex[rank] ?? 0)
            return Item(card: card, isWild: isWild, orderIdx: orderIdx)
        }.enumerated().sorted { a, b in
            let aKey = (a.element.orderIdx, a.element.card.cardSuit ?? "", a.element.card.cardID ?? "")
            let bKey = (b.element.orderIdx, b.element.card.cardSuit ?? "", b.element.card.cardID ?? "")
            if aKey != bKey { return aKey < bKey }
            return a.offset < b.offset
        }.map { $0.element }
        let deck = sorted
        let wilds = deck.indices.filter { deck[$0].isWild }

        // Candidate melds (exact-cover pieces).
        var candidates: [Set<Int>] = []
        var seenMelds = Set<Set<Int>>()

        func addCandidate(_ meld: Set<Int>) {
            if seenMelds.insert(meld).inserted {
                candidates.append(meld)
            }
        }

        // Sets: k naturals of one rank plus w wilds, at least one natural.
        var naturalsByRank: [Int: [Int]] = [:]
        for index in deck.indices where !deck[index].isWild {
            naturalsByRank[deck[index].orderIdx, default: []].append(index)
        }
        for rank in naturalsByRank.keys.sorted() {
            let naturals = naturalsByRank[rank]!
            for k in 1...naturals.count {
                for combo in combinations(naturals, k) {
                    let lowest = max(minSet - k, 0)
                    var w = lowest
                    while w <= wilds.count {
                        for wildCombo in combinations(wilds, w) {
                            addCandidate(Set(combo).union(wildCombo))
                        }
                        w += 1
                    }
                }
            }
        }

        // Runs: per suit, windows of consecutive ranks in `order`, circular
        // when `wrap`; naturals fill what they can, wilds cover the rest.
        var naturalsBySuitRank: [String: [Int: [Int]]] = [:]
        for index in deck.indices where !deck[index].isWild {
            let suit = deck[index].card.cardSuit ?? ""
            naturalsBySuitRank[suit, default: [:]][deck[index].orderIdx, default: []].append(index)
        }
        let rankCount = order.count
        for suit in naturalsBySuitRank.keys.sorted() {
            let byRank = naturalsBySuitRank[suit]!
            var seenWindows = Set<[Int]>()
            for start in 0..<rankCount {
                var window: [Int] = []
                var cursor = start
                for _ in 0..<rankCount {
                    let idx = wrap ? cursor % rankCount : cursor
                    if !wrap && idx >= rankCount { break }
                    window.append(idx)
                    cursor += 1
                    if window.count >= minRun {
                        let key = window.sorted()
                        if seenWindows.insert(key).inserted {
                            var naturals: [Int] = []
                            var missing = 0
                            for idx in window {
                                if let found = byRank[idx], let first = found.first {
                                    naturals.append(first)
                                } else {
                                    missing += 1
                                }
                            }
                            // At least one natural card in every meld.
                            if !naturals.isEmpty, missing <= wilds.count {
                                for wildCombo in combinations(wilds, missing) {
                                    addCandidate(Set(naturals).union(wildCombo))
                                }
                            }
                        }
                    }
                    if !wrap && cursor >= rankCount { break }
                }
            }
        }

        // Exact-cover DFS over deck indices with memoization; dead cards
        // pay their pip value, so the optimum minimizes deadwood. Dead
        // wilds contribute 0 (the plan pins no dead-wild value).
        var pips: [Int] = []
        for item in deck {
            if item.isWild {
                pips.append(0)
            } else {
                pips.append(try pipOrFault(rank: item.card.cardRank ?? "", call: call))
            }
        }
        var memo: [Int: (deadwood: Int, melds: [[Int]])] = [:]
        let fullMask = (1 << deck.count) - 1
        func dfs(_ mask: Int) -> (deadwood: Int, melds: [[Int]]) {
            if mask == fullMask { return (0, []) }
            if let cached = memo[mask] { return cached }
            var pivot = 0
            while mask & (1 << pivot) != 0 { pivot += 1 }

            var bestDeadwood = Int.max
            var bestMelds: [[Int]] = []
            for meld in candidates where meld.contains(pivot) {
                var usable = true
                for index in meld where index != pivot {
                    if mask & (1 << index) != 0 {
                        usable = false
                        break
                    }
                }
                guard usable else { continue }
                var nextMask = mask
                for index in meld { nextMask |= 1 << index }
                let sub = dfs(nextMask)
                if sub.deadwood < bestDeadwood {
                    bestDeadwood = sub.deadwood
                    bestMelds = [meld.sorted()] + sub.melds
                }
            }
            let dead = dfs(mask | (1 << pivot))
            if dead.deadwood + pips[pivot] < bestDeadwood {
                bestDeadwood = dead.deadwood + pips[pivot]
                bestMelds = dead.melds
            }
            let result = (bestDeadwood, bestMelds)
            memo[mask] = result
            return result
        }
        let solved = dfs(0)

        // Canonical output: each meld's cards in deck order, melds ordered
        // by their card sequences.
        func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
            for i in 0..<min(a.count, b.count) where a[i] != b[i] {
                return a[i] < b[i]
            }
            return a.count < b.count
        }
        let meldIndexLists = solved.melds.sorted(by: lexLess)
        let meldValues = meldIndexLists.map { meld -> Value in
            .list(meld.map { deck[$0].card })
        }
        return .record(
            name: "rummy.meldResult",
            fields: ["melds": .list(meldValues), "deadwood": .int(Int64(solved.deadwood))])
    }
}

/// All k-element combinations of `items`, in input order.
private func combinations(_ items: [Int], _ k: Int) -> [[Int]] {
    if k == 0 { return [[]] }
    if k > items.count { return [] }
    var result: [[Int]] = []
    var current: [Int] = []
    func pick(_ start: Int) {
        if current.count == k {
            result.append(current)
            return
        }
        for i in start..<items.count {
            current.append(items[i])
            pick(i + 1)
            current.removeLast()
        }
    }
    pick(0)
    return result
}
