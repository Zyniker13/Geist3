// Cribbage natives (P2.4): handScore and pegPoints.

extension StandardNatives {

    // MARK: - cribbage.handScore(hand, starter, isCrib)

    /// Show scoring (§5.2): fifteens 2 each, pairs 2 each, 1 per card over
    /// each maximal run, a 4-card flush in the hand (5 with a matching
    /// starter, crib flushes only with all five cards), and nobs 1.
    static let cribbageHandScore: Impl = { args in
        let call = "cribbage.handScore"
        guard args.count == 3 else { try fault(call, "expected 3 arguments") }
        let hand = try cardListArg(args[0], "hand", call)
        let starter = try cardArg(args[1], call)
        let isCrib = try boolArg(args[2], "isCrib", call)
        guard (2...5).contains(hand.count) else {
            try fault(call, "hand must hold 2 to 5 cards, got \(hand.count)")
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
        // Short piles (e.g. the two-card crib of five-card cribbage,
        // 2–3 cards here) cannot flush.
        if hand.count >= 4 {
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
    static let cribbagePegPoints: Impl = { args in
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
}
