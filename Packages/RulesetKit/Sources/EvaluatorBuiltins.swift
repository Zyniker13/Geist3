import CardExpr

/// The builtin functions of the expression language (§7.3), evaluated
/// against the environment. All builtins are pure over the environment:
/// the same environment and arguments always produce the same value.
extension Evaluator {
    mutating func evaluateBuiltin(_ builtin: BuiltinID, _ typed: TypedExpr) throws(EvaluationFault) -> Value {
        var args: [Value] = []
        args.reserveCapacity(typed.children.count)
        for child in typed.children {
            args.append(try walk(child))
        }
        switch builtin {
        case .seats, .teams, .dealtHands:
            return environmentList(builtin)
        case .left, .right, .partner, .team, .opponents, .nextActive, .zone:
            return try seatBuiltin(builtin, args)
        case .holderOf, .tricksWon, .playedBy, .choice:
            return try trackedStateBuiltin(builtin, args)
        case .rankIndex, .rankCode, .colorOf, .top:
            return try cardBuiltin(builtin, args)
        case .intCast:
            return try intCast(args)
        }
    }

    /// `int(text)`: numeric text ('2' … '10') as a number; anything else
    /// is a fault.
    private mutating func intCast(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1, case .string(let text) = args[0], let n = Int64(text) else {
            return try fault(.unsupportedValue, "int(...) expects numeric text like '10'")
        }
        return .int(n)
    }

    /// Environment listings: the seat order, the team list, and the
    /// dealt hands.
    private mutating func environmentList(_ builtin: BuiltinID) -> Value {
        switch builtin {
        case .seats:
            return .list(env.seats)
        case .teams:
            return .list(env.teams)
        default:
            return .list(env.dealtHands())
        }
    }

    /// Seat arithmetic and grouping builtins (§7.3).
    private mutating func seatBuiltin(_ builtin: BuiltinID, _ args: [Value]) throws(EvaluationFault) -> Value {
        switch builtin {
        case .left:
            return try rotateSeat(args, forward: true)
        case .right:
            return try rotateSeat(args, forward: false)
        case .partner:
            return try partnerOf(args)
        case .team:
            return try teamOf(args)
        case .opponents:
            return try opponentsOf(args)
        case .nextActive:
            return try nextActiveSeat(args)
        default:
            return try zoneOf(args)
        }
    }

    /// Tracked-state builtins: the host-run history (§7.5).
    private mutating func trackedStateBuiltin(_ builtin: BuiltinID, _ args: [Value]) throws(EvaluationFault) -> Value {
        switch builtin {
        case .holderOf:
            return env.holderOf(try requireString(args.count == 1 ? args[0] : .null, "face id"))
        case .tricksWon:
            return .int(env.tricksWon(args.count == 1 ? args[0] : .null))
        case .playedBy:
            return .list(env.playedBy(try requireString(args.count == 1 ? args[0] : .null, "seat argument")))
        default:
            return env.choice(
                try requireString(args.count == 2 ? args[0] : .null, "choice id"),
                try requireString(args.count == 2 ? args[1] : .null, "seat argument")
            )
        }
    }

    /// Card-appearance builtins over the rank order and suit colors.
    private mutating func cardBuiltin(_ builtin: BuiltinID, _ args: [Value]) throws(EvaluationFault) -> Value {
        switch builtin {
        case .rankIndex:
            return try rankIndexOf(args)
        case .rankCode:
            return try rankCodeOf(args)
        case .colorOf:
            return try colorOfSuit(args)
        default:
            return try topCards(args)
        }
    }

    // MARK: Seat arithmetic

    /// `left(s, k)` / `right(s, k)`: the seat k places left or right of
    /// s in the play order; k wraps around the table.
    private mutating func rotateSeat(_ args: [Value], forward: Bool) throws(EvaluationFault) -> Value {
        guard args.count == 2 else { return try internalArity() }
        let seat = try requireString(args[0], "seat argument")
        guard case .int(let step) = args[1] else {
            return try fault(.unsupportedValue, "internal: seat step is not an int")
        }
        let count = env.seats.count
        guard count > 0 else {
            return try fault(.unsupportedValue, "no seats are in play")
        }
        guard let index = env.seats.firstIndex(of: .string(seat)) else {
            return try fault(.unsupportedValue, "seat '\(seat)' is not in play")
        }
        let n = Int64(count)
        // step mod n, always in 0 ..< n; the modulo of an Int64 over a
        // small positive divisor cannot overflow.
        let wrapped = ((step % n) + n) % n
        let offset = forward ? Int(wrapped) : Int((n - wrapped) % n)
        return env.seats[(index + offset) % count]
    }

    /// `partner(s)`: the other member of s's team (exactly two seats
    /// per team); faults when the shape does not hold.
    private mutating func partnerOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        let seat = try requireString(args[0], "seat argument")
        guard let team = env.teamOfSeat[seat] else {
            return try fault(.unsupportedValue, "seat '\(seat)' has no team")
        }
        let mates = env.seats.compactMap { value -> String? in
            guard case .string(let name) = value, name != seat, env.teamOfSeat[name] == team else {
                return nil
            }
            return name
        }
        guard mates.count == 1 else {
            return try fault(.unsupportedValue, "seat '\(seat)' does not have exactly one partner")
        }
        return .string(mates[0])
    }

    /// `team(s)`: the team the seat belongs to.
    private mutating func teamOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        let seat = try requireString(args[0], "seat argument")
        guard let team = env.teamOfSeat[seat] else {
            return try fault(.unsupportedValue, "seat '\(seat)' has no team")
        }
        return .string(team)
    }

    /// `opponents(t)`: the one team that is not t (exactly two teams);
    /// faults when the shape does not hold.
    private mutating func opponentsOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        guard case .string(let team) = args[0] else {
            return try fault(.unsupportedValue, "internal: opponents argument is not a team")
        }
        let others = env.teams.filter { $0 != .string(team) }
        guard others.count == 1 else {
            return try fault(.unsupportedValue, "team '\(team)' does not have exactly one opponent team")
        }
        return others[0]
    }

    /// `nextActive(s)`: the first active seat after s going left,
    /// wrapping the table; s itself when no other seat is active.
    private mutating func nextActiveSeat(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        let seat = try requireString(args[0], "seat argument")
        let count = env.seats.count
        guard count > 0 else {
            return try fault(.unsupportedValue, "no seats are in play")
        }
        guard let start = env.seats.firstIndex(of: .string(seat)) else {
            return try fault(.unsupportedValue, "seat '\(seat)' is not in play")
        }
        // step in 1 ... count covers every other seat and then s itself.
        for step in 1...count {
            guard case .string(let name) = env.seats[(start + step) % count] else {
                continue
            }
            if env.activeSeats.contains(name) {
                return .string(name)
            }
        }
        return try fault(.unsupportedValue, "no active seat is next after '\(seat)'")
    }

    // MARK: Zones and state reads

    /// `zone(id)` or `zone(id, owner)`: the cards in a zone. In host
    /// evaluation the full contents are readable (§7.5); filtered reads
    /// go through the zone reader.
    private mutating func zoneOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        switch args.count {
        case 1:
            let id = try requireString(args[0], "zone id")
            guard let contents = env.zoneContents[id] else {
                return try fault(.unsupportedValue, "unknown zone '\(id)'")
            }
            return .list(contents)
        case 2:
            return .list(env.zoneReader(try requireString(args[0], "zone id"), args[1]))
        default:
            return try internalArity()
        }
    }

    // MARK: Ranks and colors

    /// `rankIndex(order, rank)`: the rank's 0-based position in a
    /// declared rank order (§7.3).
    private mutating func rankIndexOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 2 else { return try internalArity() }
        let order = try requireString(args[0], "order name")
        let rank = try requireString(args[1], "rank")
        guard let ranks = env.orders[order] else {
            return try fault(.unsupportedValue, "unknown rank order '\(order)'")
        }
        guard let index = ranks.firstIndex(of: rank) else {
            return try fault(.unsupportedValue, "rank '\(rank)' is not in order '\(order)'")
        }
        return .int(Int64(index))
    }

    /// `rankCode(rank)`: the canonical numeric code 2...14 for the
    /// standard ranks ('2'..'10', 'J', 'Q', 'K', 'A').
    private mutating func rankCodeOf(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        let rank = try requireString(args[0], "rank")
        if let number = Int(rank), number >= 2, number <= 10 {
            return .int(Int64(number))
        }
        switch rank {
        case "J": return .int(11)
        case "Q": return .int(12)
        case "K": return .int(13)
        case "A": return .int(14)
        default:
            return try fault(.unsupportedValue, "unknown rank '\(rank)'")
        }
    }

    /// `colorOf(suit)`: 'red' for hearts and diamonds, 'black' for
    /// spades and clubs; faults on any other suit.
    private mutating func colorOfSuit(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        let suit = try requireString(args[0], "suit")
        switch suit {
        case "H", "D": return .string("red")
        case "S", "C": return .string("black")
        default:
            return try fault(.unsupportedValue, "unknown suit '\(suit)'")
        }
    }

    /// `top(n)`: the first n cards of the contextual 'cards' binding
    /// (the zone the rule is inspecting); a negative n faults.
    private mutating func topCards(_ args: [Value]) throws(EvaluationFault) -> Value {
        guard args.count == 1 else { return try internalArity() }
        guard case .int(let n) = args[0] else {
            return try fault(.unsupportedValue, "internal: top count is not an int")
        }
        guard n >= 0 else {
            return try fault(.unsupportedValue, "top count is negative")
        }
        guard case .list(let cards) = env.contextual["cards"] ?? .list([]) else {
            return try fault(.unsupportedValue, "internal: 'cards' is not bound as a list here")
        }
        let count = min(n, Int64(cards.count))
        return .list(Array(cards.prefix(Int(count))))
    }

    // MARK: Shared helpers

    /// Unwraps a string-typed value or faults when the checker contract
    /// is violated (an internal error, not a ruleset authoring error).
    private func requireString(_ value: Value, _ what: String) throws(EvaluationFault) -> String {
        guard case .string(let string) = value else {
            return try fault(.unsupportedValue, "internal: \(what) is not a string")
        }
        return string
    }

    private func internalArity<T>() throws(EvaluationFault) -> T {
        return try fault(.unsupportedValue, "internal: builtin argument arity mismatch")
    }
}
