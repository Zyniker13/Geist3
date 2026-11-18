// The `deal` mechanic (ARCHITECTURE §5.6): dealing packets to hands from a
// source zone. P1 minimal Swift-configured form.

import CardModel

public struct DealPacket: Codable, Hashable, Sendable {
    public let to: Seat
    /// Cards per packet.
    public let each: Int
    /// Number of packets for this seat (default 1).
    public let packets: Int
    /// Whether the dealt cards become known to their owner.
    public let faceUp: Bool

    public init(to: Seat, each: Int, packets: Int = 1, faceUp: Bool = false) {
        self.to = to
        self.each = each
        self.packets = packets
        self.faceUp = faceUp
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
            let target = ZoneKey(scope: .seat, owner: packet.to.raw, id: "hand")
            state.zones.declare(target)
            var dealt: [CardInstance] = []
            for _ in 0..<(packet.each * packet.packets) {
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
                } else {
                    state.knowledge.reveal(instance.id, to: SeatSet(packet.to))
                }
                dealt.append(instance)
            }
            events.append(.dealt(to: packet.to, cards: dealt))
        }
        return events
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
