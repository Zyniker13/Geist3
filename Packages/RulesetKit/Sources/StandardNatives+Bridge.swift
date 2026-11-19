// Bridge natives (P2.4): score and honors.

extension StandardNatives {

    // MARK: - bridge.score(contract, tricks, vulnerable, mode)

    /// Contract bridge scoring (§5.3) for one deal. Rubber mode reports the
    /// trick score in `below` and overtricks, slams, and insult in `above`
    /// (game and part bonuses belong to the match store); chicago and
    /// duplicate add the per-deal game (300/500) or part-score (50) bonus to
    /// `above`. A set contract reports the penalty in `defenders` and leaves
    /// `below`/`above` at 0.
    static let bridgeScore: Impl = { args in
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

    /// Parse the first `bridge.honors` argument into four hands of cards.
    static func parseHands(_ args: [Value], _ call: String) throws(EvaluationFault) -> [[Value]] {
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
        guard hands.count == 4 else {
            try fault(call, "expected 4 hands, got \(hands.count)")
        }
        return hands
    }

    /// The honors bonus for the partnership's combined `cards` under `trump`
    /// (a suit, or `null` for the no-trump aces bonus).
    static func honorsBonus(cards: [Value], trump: Value) throws(EvaluationFault) -> Int {
        if case .null = trump {
            let aces = cards.filter { $0.cardRank == "A" }.count
            return aces == 4 ? 150 : 0
        }
        guard case .string(let trumpSuit) = trump else {
            try fault("bridge.honors", "trump must be a suit or null")
        }
        let honorRanks: Set<String> = ["A", "K", "Q", "J", "10"]
        let honors = cards.filter {
            $0.cardSuit == trumpSuit && honorRanks.contains($0.cardRank ?? "")
        }.count
        return honors >= 5 ? 150 : (honors == 4 ? 100 : 0)
    }

    /// Honors bonus (§5.3): 100 for four trump honors (A K Q J 10) held by
    /// the partnership, 150 for all five, or 150 for all four aces at
    /// no-trump. The team resolves through the installed teams list.
    static func bridgeHonors(teams: [Value]) -> Impl {
        return { args in
            let call = "bridge.honors"
            guard args.count == 3 else { try fault(call, "expected 3 arguments") }
            let hands = try parseHands(args, call)
            let trump = args[1]
            let team = args[2]
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
            return .int(Int64(try honorsBonus(cards: cards, trump: trump)))
        }
    }
}
