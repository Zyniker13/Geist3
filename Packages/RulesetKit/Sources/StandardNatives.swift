import CardExpr

/// Reference implementations of the §5.8 natives the reference rulesets
/// call. The engine installs `all(teams:)` into `EvaluationEnvironment.natives`;
/// tests install it directly. Every failure raises `EvaluationFault` with
/// kind `unsupportedValue` and a `natives/<name>` pointer; the engine maps it
/// onto a rule violation carrying the expression's real pointer.
///
/// Scoring semantics (ADR-0025):
/// - `bridge.score` `total` counts the declarer side only (`below + above`);
///   a set contract reports the penalty through `defenders` alone, which is
///   how the Chicago overlay awards both sides.
/// - Chicago and duplicate use per-deal bonus scoring (game 300/500,
///   part-score 50); rubber leaves game and part bonuses to the match store.
/// - `bridge.honors` resolves its team argument against the `teams` list the
///   host installs: team index `i` holds the alternating seats `j % 2 == i`
///   (§5.4 partnershipOpposite).
/// - `rummy.melds` returns an optimal meld partition: minimal deadwood, ties
///   broken by the first partition the deterministic search reaches. Melds
///   must contain at least one natural card.
public enum StandardNatives {

    /// The implementation type `EvaluationEnvironment.natives` stores.
    public typealias Impl = @Sendable ([Value]) throws(EvaluationFault) -> Value

    /// All reference natives. `teams` is the ruleset's ordered team list;
    /// `bridge.honors` needs it to map a team to its two seats.
    public static func all(teams: [Value] = []) -> [String: Impl] {
        return [
            "cribbage.handScore": cribbageHandScore,
            "cribbage.pegPoints": cribbagePegPoints,
            "bridge.score": bridgeScore,
            "bridge.honors": bridgeHonors(teams: teams),
            "rummy.melds": rummyMelds,
        ]
    }

    // MARK: - Argument helpers

    private static func fault(_ call: String, _ message: String) throws(EvaluationFault) -> Never {
        throw EvaluationFault(
            kind: .unsupportedValue, pointer: "natives/\(call)", message: message)
    }

    private static func intArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> Int {
        guard case .int(let n) = v else {
            try fault(call, "\(label) must be an int")
        }
        return Int(n)
    }

    private static func boolArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> Bool {
        guard case .bool(let b) = v else {
            try fault(call, "\(label) must be a bool")
        }
        return b
    }

    private static func stringArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> String {
        guard case .string(let s) = v else {
            try fault(call, "\(label) must be a string")
        }
        return s
    }

    private static func cardArg(_ v: Value, _ call: String) throws(EvaluationFault) -> Value {
        guard case .card = v else {
            try fault(call, "expected a card")
        }
        return v
    }

    private static func cardListArg(
        _ v: Value, _ label: String, _ call: String
    ) throws(EvaluationFault) -> [Value] {
        guard case .list(let items) = v else {
            try fault(call, "\(label) must be a list of cards")
        }
        for item in items {
            guard case .card = item else {
                try fault(call, "\(label) must be a list of cards")
            }
        }
        return items
    }

    private static func recordArg(
        _ v: Value, _ name: String, _ call: String
    ) throws(EvaluationFault) -> [String: Value] {
        guard case .record(let recordName, let fields) = v, recordName == name else {
            try fault(call, "expected a \(name) record")
        }
        return fields
    }

    private static func recordField(
        _ fields: [String: Value], _ key: String, _ call: String
    ) throws(EvaluationFault) -> Value {
        guard let v = fields[key] else {
            try fault(call, "record is missing field '\(key)'")
        }
        return v
    }

    /// The pip value of a rank (§5.2, §5.3): ace 1, cards 2–10 face value,
    /// court cards 10.
    private static func pip(rank: String) -> Int? {
        if rank == "A" { return 1 }
        if let n = Int(rank), (2...10).contains(n) { return n }
        if ["J", "Q", "K"].contains(rank) { return 10 }
        return nil
    }

    private static func pipOrFault(
        rank: String, call: String
    ) throws(EvaluationFault) -> Int {
        guard let value = pip(rank: rank) else {
            try fault(call, "card of rank '\(rank)' has no pip value")
        }
        return value
    }

    /// The standard french rank order, ace low, as indices 0…12.
    private static let frenchRanks = [
        "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
    ]

    // MARK: - cribbage.handScore(hand, starter, isCrib)

    /// Show scoring (§5.2): fifteens 2 each, pairs 2 each, 1 per card over
    /// each maximal run, a 4-card flush in the hand (5 with a matching
    /// starter, crib flushes only with all five cards), and nobs 1.
    private static let cribbageHandScore: Impl = { args in
        let call = "cribbage.handScore"
        guard args.count == 3 else { try fault(call, "expected 3 arguments") }
        let hand = try cardListArg(args[0], "hand", call)
        let starter = try cardArg(args[1], call)
        let isCrib = try boolArg(args[2], "isCrib", call)
        guard hand.count == 4 else {
            try fault(call, "hand must hold exactly 4 cards, got \(hand.count)")
        }
        var seen: Set<String> = []
        for card in hand {
            let key = "\(card.cardSuit ?? "")|\(card.cardRank ?? "")"
            guard seen.insert(key).inserted else {
                try fault(call, "hand contains duplicate cards")
            }
        }
        let starterKey = "\(starter.cardSuit ?? "")|\(starter.cardRank ?? "")"
        if seen.contains(starterKey) {
            try fault(call, "starter duplicates a hand card")
        }

        var score = 0
        let all = hand + [starter]
        var pips: [Int] = []
        var rankCounts: [Int: Int] = [:]
        for card in all {
            pips.append(try pipOrFault(rank: card.cardRank ?? "", call: call))
            if let idx = frenchRanks.firstIndex(of: card.cardRank ?? "") {
                rankCounts[idx, default: 0] += 1
            }
        }

        // Fifteens: every non-empty subset of the five cards summing to 15.
        for mask in 1..<(1 << all.count) {
            var sum = 0
            for i in 0..<all.count where mask & (1 << i) != 0 { sum += pips[i] }
            if sum == 15 { score += 2 }
        }

        // Pairs: 2 per unordered pair of equal rank.
        for i in 0..<all.count {
            for j in (i + 1)..<all.count where all[i].cardRank == all[j].cardRank {
                score += 2
            }
        }

        // Runs: each maximal window of 3+ consecutive ranks (ace low, no
        // wrap) scores its length times the number of distinct ways the
        // available copies form it.
        for start in 0..<frenchRanks.count {
            let blockedLeft = start == 0 || (rankCounts[start - 1] ?? 0) == 0
            guard blockedLeft, let first = rankCounts[start], first > 0 else { continue }
            var length = 0
            var multiplicity = 1
            var index = start
            while index < frenchRanks.count, let count = rankCounts[index], count > 0 {
                multiplicity *= count
                length += 1
                index += 1
            }
            if length >= 3 { score += length * multiplicity }
        }

        // Flushes: four hand cards of one suit score 4 (plus 1 with a
        // matching starter); in the crib only a five-card flush scores.
        let suits = Set(hand.map { $0.cardSuit ?? "" })
        if suits.count == 1 {
            let handSuit = hand[0].cardSuit ?? ""
            if isCrib {
                if starter.cardSuit == handSuit { score += 5 }
            } else {
                score += 4
                if starter.cardSuit == handSuit { score += 1 }
            }
        }

        // Nobs: a jack of the starter's suit in the hand (the starter's
        // own rank is irrelevant).
        if hand.contains(where: { $0.cardRank == "J" && $0.cardSuit == starter.cardSuit }) {
            score += 1
        }

        return .int(Int64(score))
    }

    // MARK: - cribbage.pegPoints(sequence)

    /// Pegging points for the card just played (§5.2), given the ordered
    /// count zone since the last reset: fifteens 2, 2 per pair among the
    /// equal-rank cards in the run, and the longest run through the last
    /// card with multiplicities (a doubled run counts twice).
    private static let cribbagePegPoints: Impl = { args in
        let call = "cribbage.pegPoints"
        guard args.count == 1 else { try fault(call, "expected 1 argument") }
        let sequence = try cardListArg(args[0], "sequence", call)
        guard let last = sequence.last else { return .int(0) }

        var score = 0

        // Fifteens: the running total of the whole count run.
        var total = 0
        for card in sequence {
            total += try pipOrFault(rank: card.cardRank ?? "", call: call)
        }
        if total == 15 { score += 2 }

        // Pairs royal: 2 per pair among the equal-rank cards in the run.
        let lastRank = last.cardRank ?? ""
        let sameRank = sequence.filter { $0.cardRank == lastRank }.count
        score += 2 * sameRank * (sameRank - 1) / 2

        // Runs: the best-scoring suffix of the count run (3+ cards) whose
        // distinct ranks are consecutive. One point per rank in the run,
        // times one factor per way to pick a card of each rank, so a
        // doubled run (5,5,6,7) scores twice its span and a tripled one
        // three times.
        var bestRun = 0
        if sequence.count >= 3 {
            for n in 3...sequence.count {
                var counts: [Int: Int] = [:]
                var ranksKnown = true
                for card in sequence.suffix(n) {
                    guard let idx = frenchRanks.firstIndex(of: card.cardRank ?? "") else {
                        ranksKnown = false
                        break
                    }
                    counts[idx, default: 0] += 1
                }
                guard ranksKnown, counts.count >= 3 else { continue }
                let low = counts.keys.min() ?? 0
                let high = counts.keys.max() ?? 0
                guard high - low + 1 == counts.count else { continue }
                var ways = 1
                for count in counts.values { ways *= count }
                bestRun = max(bestRun, counts.count * ways)
            }
        }
        score += bestRun

        return .int(Int64(score))
    }

    // MARK: - bridge.score(contract, tricks, vulnerable, mode)

    /// Contract bridge scoring (§5.3) for one deal. Rubber mode reports the
    /// trick score in `below` and overtricks, slams, and insult in `above`
    /// (game and part bonuses belong to the match store); chicago and
    /// duplicate add the per-deal game (300/500) or part-score (50) bonus to
    /// `above`. A set contract reports the penalty in `defenders` and leaves
    /// `below`/`above` at 0.
    private static let bridgeScore: Impl = { args in
        let call = "bridge.score"
        guard args.count == 4 else { try fault(call, "expected 4 arguments") }
        let contract = try recordArg(args[0], "contract", call)
        let tricks = try intArg(args[1], "tricks", call)
        let vulnerable = try boolArg(args[2], "vulnerable", call)
        let mode = try stringArg(args[3], "mode", call)
        guard mode == "rubber" || mode == "chicago" || mode == "duplicate" else {
            try fault(call, "unknown scoring mode '\(mode)'")
        }
        guard tricks >= 0 && tricks <= 13 else {
            try fault(call, "tricks \(tricks) out of range 0…13")
        }

        let level = try intArg(try recordField(contract, "level", call), "level", call)
        let strain = try stringArg(try recordField(contract, "strain", call), "strain", call)
        let doubled = contract["doubled"] == .bool(true)
        let redoubled = contract["redoubled"] == .bool(true)
        guard level >= 1 && level <= 7 else {
            try fault(call, "contract level \(level) out of range 1…7")
        }
        // Trick score (§5.3): minors 20 per trick, majors 30 per trick,
        // and notrump 40 for the first trick plus 30 for each further one —
        // so the notrump total 40+30·(level−1) is already cumulative.
        let undoubledTrickScore: Int
        switch strain {
        case "C", "D": undoubledTrickScore = 20 * level
        case "H", "S": undoubledTrickScore = 30 * level
        case "NT": undoubledTrickScore = 40 + 30 * (level - 1)
        default: try fault(call, "unknown strain '\(strain)'")
        }
        let multiplier = redoubled ? 4 : (doubled ? 2 : 1)
        let needed = 6 + level

        var below = 0
        var above = 0
        var defenders = 0

        if tricks >= needed {
            let trickScore = undoubledTrickScore * multiplier
            below = trickScore
            let over = tricks - needed

            // Overtricks: undoubled at the strain's trick rate (minors 20,
            // majors 30, notrump 30); doubled/redoubled at the fixed
            // per-trick rates (the same in rubber and duplicate).
            if multiplier == 1 {
                let overRate: Int
                switch strain {
                case "C", "D": overRate = 20
                case "H", "S", "NT": overRate = 30
                default: overRate = 0
                }
                above += overRate * over
            } else {
                let overRate = redoubled ? (vulnerable ? 400 : 200) : (vulnerable ? 200 : 100)
                above += overRate * over
            }

            // Slam bonuses above the line in every mode.
            if level == 6 { above += vulnerable ? 750 : 500 }
            if level == 7 { above += vulnerable ? 1500 : 1000 }

            // Insult for doubling the contract.
            if multiplier == 2 { above += 50 }
            if multiplier == 4 { above += 100 }

            if mode != "rubber" {
                // Chicago and duplicate score the game/part bonus per deal.
                above += trickScore >= 100 ? (vulnerable ? 500 : 300) : 50
            }
        } else {
            let under = needed - tricks
            if multiplier == 1 {
                defenders = (vulnerable ? 100 : 50) * under
            } else {
                // Doubled undertrick penalties (Laws of Duplicate Bridge
                // 77): not vulnerable the first undertrick is 100, the
                // second 200 more, the third 200 more, and 300 each
                // thereafter (cumulative 100, 300, 500, 800, 1100, 1400,
                // …); vulnerable 200 for the first and 300 each
                // thereafter (200, 500, 800, 1100, 1400, 1700, …).
                // Redoubled doubles the doubled penalty.
                var penalty: Int
                if vulnerable {
                    penalty = 200 + 300 * (under - 1)
                } else {
                    penalty = under == 1 ? 100 : (under == 2 ? 300 : 500 + 300 * (under - 3))
                }
                if redoubled { penalty *= 2 }
                defenders = penalty
            }
        }

        return .record(
            name: "bridge.scoreResult",
            fields: [
                "below": .int(Int64(below)),
                "above": .int(Int64(above)),
                "defenders": .int(Int64(defenders)),
                "total": .int(Int64(below + above)),
            ])
    }

    // MARK: - bridge.honors(hands, trump, team)

    /// Honors bonus (§5.3): 100 for four trump honors (A K Q J 10) held by
    /// the partnership, 150 for all five, or 150 for all four aces at
    /// no-trump. The team resolves through the installed teams list.
    private static func bridgeHonors(teams: [Value]) -> Impl {
        return { args in
            let call = "bridge.honors"
            guard args.count == 3 else { try fault(call, "expected 3 arguments") }
            guard case .list(let handValues) = args[0] else {
                try fault(call, "hands must be a list of lists of cards")
            }
            var hands: [[Value]] = []
            for handValue in handValues {
                guard case .list(let cards) = handValue else {
                    try fault(call, "hands must be a list of lists of cards")
                }
                for card in cards {
                    guard case .card = card else {
                        try fault(call, "hands must be a list of lists of cards")
                    }
                }
                hands.append(cards)
            }
            let trump = args[1]
            let team = args[2]
            guard hands.count == 4 else {
                try fault(call, "expected 4 hands, got \(hands.count)")
            }
            if case .string(let trumpSuit) = trump {
                guard ["C", "D", "H", "S"].contains(trumpSuit) else {
                    try fault(call, "trump must be C, D, H, or S, got \(trumpSuit)")
                }
            }
            guard let teamIndex = teams.firstIndex(where: { $0 == team }) else {
                try fault(call, "team not in the installed teams table")
            }
            let cards = hands.enumerated()
                .filter { $0.offset % 2 == teamIndex % 2 }
                .flatMap { $0.element }

            if case .null = trump {
                let aces = cards.filter { $0.cardRank == "A" }.count
                return .int(Int64(aces == 4 ? 150 : 0))
            }
            guard case .string(let trumpSuit) = trump else {
                try fault(call, "trump must be a suit or null")
            }
            let honorRanks: Set<String> = ["A", "K", "Q", "J", "10"]
            let honors = cards.filter {
                $0.cardSuit == trumpSuit && honorRanks.contains($0.cardRank ?? "")
            }.count
            let bonus = honors >= 5 ? 150 : (honors == 4 ? 100 : 0)
            return .int(Int64(bonus))
        }
    }

    // MARK: - rummy.melds(cards, rules)

    /// Optimal meld finding (§5.3): sets of `minSet`+ cards of one rank and
    /// runs of `minRun`+ consecutive same-suit ranks (ace low or high per
    /// the rules record, circular with `wrap`), wild ranks standing for any
    /// card. Returns the partition with the least deadwood that the
    /// deterministic search reaches first.
    private static let rummyMelds: Impl = { args in
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
                    if mask & (1 << index) != 0 { usable = false; break }
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
            for i in 0..<min(a.count, b.count) {
                if a[i] != b[i] { return a[i] < b[i] }
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
