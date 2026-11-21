// The `deal` mechanic (ARCHITECTURE §5.6): dealing packets to hands from a
// source zone. P1 minimal Swift-configured form.

import CardModel

/// One JSON-configured count expression on a deal packet (§5.6): kept in
/// source form and evaluated at deal time through the host runtime.
public struct DealCountExpr: Codable, Hashable, Sendable {
    /// The expression source.
    public let source: String
    /// JSON pointer of the expression, used in faults.
    public let pointer: String

    public init(source: String, pointer: String) {
        self.source = source
        self.pointer = pointer
    }
}

public struct DealPacket: Codable, Hashable, Sendable {
    /// Target zone. JSON rulesets name a zone id; seat-scoped zones deal to
    /// every owner seat in turn (EngineBuilder expands them per owner).
    public let to: ZoneKey
    /// Cards per packet.
    public let each: Int
    /// Number of packets for this target (default 1).
    public let packets: Int
    /// Total cards to move, overriding `each * packets` (JSON `count`).
    public let count: Int?
    /// Whether the dealt cards become known to their owner.
    public let faceUp: Bool
    /// JSON `each` as an expression; overrides `each` when non-nil.
    public let eachExpr: DealCountExpr?
    /// JSON `count` as an expression; overrides `count` when non-nil.
    public let countExpr: DealCountExpr?

    public init(
        to: ZoneKey, each: Int, packets: Int = 1, count: Int? = nil, faceUp: Bool = false,
        eachExpr: DealCountExpr? = nil, countExpr: DealCountExpr? = nil
    ) {
        self.to = to
        self.each = each
        self.packets = packets
        self.count = count
        self.faceUp = faceUp
        self.eachExpr = eachExpr
        self.countExpr = countExpr
    }

    /// Convenience for dealing to a seat's hand zone.
    public init(to seat: Seat, each: Int, packets: Int = 1, faceUp: Bool = false) {
        self.init(to: ZoneKey(scope: .seat, owner: seat.raw, id: "hand"), each: each, packets: packets, faceUp: faceUp)
    }
}

public struct DealParams: Codable, Hashable, Sendable {
    /// Zone the cards come from (top of the zone = end of the array).
    public let source: String
    public let packets: [DealPacket]
    /// Shuffle the source zone before dealing (uses the state's RNG).
    public let shuffleFirst: Bool
    /// Cut depth before dealing (0 = no cut).
    public let cutDepth: Int
    /// Faces to place into the source zone when it is empty (deal setup for
    /// Swift-configured games; JSON rulesets set zones up instead).
    public let deckFaces: [CardFace]?

    public init(
        source: String, packets: [DealPacket], shuffleFirst: Bool, cutDepth: Int = 0, deckFaces: [CardFace]? = nil
    ) {
        self.source = source
        self.packets = packets
        self.shuffleFirst = shuffleFirst
        self.cutDepth = cutDepth
        self.deckFaces = deckFaces
    }
}

@_spi(HostOnly)
public enum DealMechanic: Mechanic {
    public static let id = "deal"

    public typealias Params = DealParams

    public static func enter(
        _ params: Params, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        var events: [GameEvent] = []
        // §7.5: record the cards each seat was dealt this deal so score-time
        // expressions (`dealtHands()`) see the original hands after play.
        var dealtRecord: [Int: [CardInstance]] = [:]
        let sourceKey = ZoneKey(scope: .shared, id: params.source)
        if state.zones.cards(in: sourceKey).isEmpty, let faces = params.deckFaces {
            // Deal setup: declare the zone and stack the deck (placeholder
            // IDs; real CardIDs are assigned post-shuffle below).
            state.zones.declare(sourceKey)
            for (index, face) in faces.enumerated() {
                try? state.zones.place(
                    CardInstance(id: CardID(UInt16(0xFF00 + UInt16(index))), face: face), in: sourceKey)
            }
        }
        if params.shuffleFirst {
            state.zones.shuffleZone(sourceKey, using: &state.rng)
        }
        // Card instance IDs are assigned here: after the shuffle, in dealing
        // order, fresh each deal (§9.5 anti-leak rule).
        var nextID: UInt16 = 0
        for packet in params.packets {
            let target = packet.to
            let total = try Self.packetTotal(packet, state: state, ctx: ctx)
            state.zones.ensureDeclared(target)
            var dealt: [CardInstance] = []
            for _ in 0..<total {
                let popped = try? state.zones.popTop(from: sourceKey)
                guard let card = popped ?? nil else {
                    throw RuleViolation.engineFault(ruleId: "deal.empty", pointer: "source \(params.source) exhausted")
                }
                let instance = CardInstance(id: CardID(nextID), face: card.face)
                nextID &+= 1
                do {
                    try state.zones.place(instance, in: target)
                } catch {
                    throw RuleViolation.engineFault(ruleId: "deal.place", pointer: "\(error)")
                }
                if packet.faceUp {
                    state.knowledge.reveal(instance.id, to: SeatSet.allSeats(ctx.seatCount))
                } else if target.scope == .seat {
                    state.knowledge.reveal(instance.id, to: SeatSet(Seat(target.owner)))
                }
                dealt.append(instance)
            }
            if target.scope == .seat {
                dealtRecord[Seat(target.owner).raw, default: []].append(contentsOf: dealt)
                events.append(.dealt(to: Seat(target.owner), cards: dealt))
            } else {
                events.append(.cardsMoved(from: params.source, to: target.id, count: total))
            }
        }
        state.dealt = dealtRecord
        return events
    }

    /// Resolves a packet's total card count: JSON expressions evaluated at
    /// deal time override the fixed fields (§5.6).
    private static func packetTotal(
        _ packet: DealPacket, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Int {
        let each = try resolveCount(packet.eachExpr, fallback: packet.each, state: state, ctx: ctx)
        if let expr = packet.countExpr {
            return try resolveCount(expr, fallback: 0, state: state, ctx: ctx)
        }
        if let count = packet.count {
            return count
        }
        return each * packet.packets
    }

    /// Evaluates one deal-count expression; a non-integer (or negative)
    /// result is an engine fault carrying the JSON pointer (§7.4).
    private static func resolveCount(
        _ expr: DealCountExpr?, fallback: Int, state: GameState, ctx: EvalContext
    ) throws(RuleViolation) -> Int {
        guard let expr else { return fallback }
        let value = try ctx.evalCall(
            EvalCall(pointer: expr.pointer, source: expr.source, ruleId: "deal.count"),
            state: state, ruleId: "deal.count")
        guard case .int(let n) = value, n >= 0, let exact = Int(exactly: n) else {
            throw RuleViolation.engineFault(
                ruleId: "deal.count",
                pointer: "\(expr.pointer) deal count must be a non-negative integer")
        }
        return exact
    }

    public static func legalIntents(
        _ params: Params, state: GameState, seat: Seat, ctx: EvalContext
    ) -> [ActionIntent] {
        []  // dealing is automatic
    }

    public static func apply(
        _ params: Params, intent: ActionIntent, by seat: Seat, state: inout GameState, ctx: EvalContext
    ) throws(RuleViolation) -> [GameEvent] {
        throw RuleViolation.illegal(ruleId: "deal.automatic", detail: .custom("dealing is not player-driven"))
    }

    public static func isComplete(_ params: Params, state: GameState, ctx: EvalContext) -> PhaseOutcome {
        .complete
    }

    public static func pendingSeats(_ params: Params, state: GameState, ctx: EvalContext) -> SeatSet {
        SeatSet()  // nobody acts during dealing
    }
}

extension SeatSet {
    /// All seats 0..<count.
    public static func allSeats(_ count: Int) -> SeatSet {
        var set = SeatSet()
        for i in 0..<count { set.insert(Seat(i)) }
        return set
    }
}
