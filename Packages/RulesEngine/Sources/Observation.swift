// Observation and Redactor (ARCHITECTURE §9.6). Redaction is the single
// function every outbound path uses; hidden faces never leave the host.

import CardModel
import Foundation

public struct ObservedPhase: Codable, Hashable, Sendable {
    public let phaseID: String
    public let pendingSeats: SeatSet

    public init(phaseID: String, pendingSeats: SeatSet) {
        self.phaseID = phaseID
        self.pendingSeats = pendingSeats
    }
}

public enum ObservedZone: Codable, Hashable, Sendable {
    /// Viewer may see every card, in order.
    case visible([CardInstance])
    /// Count plus the subset this viewer knows (§9.5: no IDs in zone order
    /// beyond known cards).
    case hidden(count: Int, known: [CardInstance])

    private enum CodingKeys: String, CodingKey { case visible, hidden, count, known }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cards = try? container.decode([CardInstance].self, forKey: .visible) {
            self = .visible(cards)
        } else {
            let count = try container.decode(Int.self, forKey: .count)
            let known = try container.decodeIfPresent([CardInstance].self, forKey: .known) ?? []
            self = .hidden(count: count, known: known)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .visible(let cards):
            try container.encode(cards, forKey: .visible)
        case .hidden(let count, let known):
            try container.encode(count, forKey: .count)
            if !known.isEmpty { try container.encode(known, forKey: .known) }
        }
    }
}

/// The seat's eye-level view (§9.6).
public struct Observation: Codable, Hashable, Sendable {
    /// SHA-256 of the resolved ruleset (32 bytes; Data keeps the struct
    /// Codable without depending on CryptoKit in the engine API).
    public let rulesetHash: Data
    public let version: UInt64
    public let viewer: ObservedViewer
    public let dealIndex: Int
    public let dealer: Seat
    public let phase: ObservedPhase
    public let zones: [String: ObservedZone]
    public let legal: [ActionIntent]
    public let lastEvents: [GameEvent]

    public init(
        rulesetHash: Data,
        version: UInt64,
        viewer: ObservedViewer,
        dealIndex: Int,
        dealer: Seat,
        phase: ObservedPhase,
        zones: [String: ObservedZone],
        legal: [ActionIntent],
        lastEvents: [GameEvent]
    ) {
        self.rulesetHash = rulesetHash
        self.version = version
        self.viewer = viewer
        self.dealIndex = dealIndex
        self.dealer = dealer
        self.phase = phase
        self.zones = zones
        self.legal = legal
        self.lastEvents = lastEvents
    }
}

/// Codable form of Viewer (Observation must be JSON-encodable for the
/// byte-scan redaction test and the wire).
public enum ObservedViewer: Codable, Hashable, Sendable {
    case seat(Int)
    case coachOf(Int)
    case table
    case spectator
    case replayAll
}

public enum Redactor {
    /// Whether the viewer may see this card's face.
    public static func maySee(_ id: CardID, viewer: Viewer, knowledge: KnowledgeStore, publicCard: Bool) -> Bool {
        switch viewer {
        case .replayAll:
            return true
        case .table, .spectator:
            return publicCard || knowledge.isPublic(id)
        case .seat(let s), .coachOf(let s):
            return knowledge.knows(id, s)
        }
    }

    /// Redact one zone per viewer.
    public static func redact(
        _ cards: [CardInstance], key: ZoneKey, viewer: Viewer, knowledge: KnowledgeStore
    ) -> ObservedZone {
        ObservedZone.redactCards(cards, key: key, viewer: viewer, knowledge: knowledge)
    }

    /// Redact an event: hidden faces become counts. An event that would
    /// disclose a hidden face to this viewer is emptied of those cards.
    public static func redact(_ event: GameEvent, viewer: Viewer, knowledge: KnowledgeStore) -> GameEvent {
        func cards(_ list: [CardInstance]) -> [CardInstance] {
            list.filter { maySee($0.id, viewer: viewer, knowledge: knowledge, publicCard: knowledge.isPublic($0.id)) }
        }
        switch event {
        case .dealt(let to, let list):
            // A dealt hand is visible only to its owner (and public cards).
            if case .seat(let s) = viewer, to == s { return .dealt(to: to, cards: list) }
            return .dealt(to: to, cards: cards(list))
        case .passed(let from, let to, let list):
            if case .seat(let s) = viewer, to == s || from == s { return .passed(from: from, to: to, cards: list) }
            return .passed(from: from, to: to, cards: cards(list))
        case .cardPlayed(let seat, let card):
            // Played cards are normally public by the time they are
            // observed (the trick zone's grant publishes them before the
            // observation is built), but `lastEvents` survives a deal
            // change: the automatic advance that ends deal N and deals N+1
            // carries deal N's play events into a state whose knowledge
            // store was wiped and refilled, where those card IDs now name
            // hidden hand cards. Filter like every other card-carrying
            // event (ADR-0038: the knowledge store is the single redaction
            // authority); within a deal this changes nothing. The hidden
            // form keeps the seat (who played is public) and drops the
            // face (suit+rank), so no byte of the face ID can leak.
            guard
                maySee(
                    card.id, viewer: viewer, knowledge: knowledge,
                    publicCard: knowledge.isPublic(card.id))
            else {
                return .cardPlayed(
                    seat: seat,
                    card: CardInstance(id: card.id, face: CardFace(suit: nil, rank: Rank(""))))
            }
            return .cardPlayed(seat: seat, card: card)
        case .trickWon(let seat, let list):
            return .trickWon(seat: seat, cards: cards(list))
        case .revealed(let zone, let list):
            return .revealed(zone: zone, cards: cards(list))
        default:
            return event
        }
    }
}
