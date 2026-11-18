// GameState (ARCHITECTURE §9.1). Host-only: bots and UI consume Observation.
// Hashable is order-stable: dictionary iteration order must not affect the
// hash, so hashable dictionaries are reduced over sorted keys.

import CardModel

/// Logged action for replays and review (§9.1 `history`).
public struct LoggedAction: Codable, Hashable, Sendable {
    public let seat: Seat
    public let intent: ActionIntent
    public let version: UInt64

    public init(seat: Seat, intent: ActionIntent, version: UInt64) {
        self.seat = seat
        self.intent = intent
        self.version = version
    }
}

/// The full state of one session. Host-only via @_spi(HostOnly): nothing
/// outside the host and engine may see the full state (§9.6, CONVENTIONS §5).
@_spi(HostOnly)
public struct GameState: Codable, Hashable, Sendable {
    public var rng: SeededRNG
    public var matchVars: VarStore
    public var dealVars: VarStore
    public var zones: ZoneStore
    public var knowledge: KnowledgeStore
    public var dealIndex: Int
    public var dealer: Seat
    public var phase: PhaseCursor
    public var history: [LoggedAction]
    public var recentEvents: [GameEvent]
    public var version: UInt64

    static let recentEventLimit = 32

    public init(
        rng: SeededRNG,
        matchVars: VarStore = VarStore(),
        dealVars: VarStore = VarStore(),
        zones: ZoneStore = ZoneStore(),
        knowledge: KnowledgeStore = KnowledgeStore(),
        dealIndex: Int = 0,
        dealer: Seat = Seat(0),
        phase: PhaseCursor = PhaseCursor(phaseID: "setup"),
        history: [LoggedAction] = [],
        recentEvents: [GameEvent] = [],
        version: UInt64 = 0
    ) {
        self.rng = rng
        self.matchVars = matchVars
        self.dealVars = dealVars
        self.zones = zones
        self.knowledge = knowledge
        self.dealIndex = dealIndex
        self.dealer = dealer
        self.phase = phase
        self.history = history
        self.recentEvents = recentEvents
        self.version = version
    }

    // MARK: - Mechanic sub-state accessors (typed convenience)

    func trickSubstate() -> TrickSubstate {
        if case .trick(let sub) = phase.substate { return sub }
        return TrickSubstate(leader: Seat(0), seatCount: 2)
    }

    mutating func setSubstate(_ sub: TrickSubstate) {
        phase = PhaseCursor(phaseID: phase.phaseID, substate: .trick(sub))
    }

    mutating func mutateSubstate(_ mutate: (inout TrickSubstate) -> Void) {
        var sub = trickSubstate()
        mutate(&sub)
        setSubstate(sub)
    }

    /// Advance to a phase and reset its mechanic sub-state.
    mutating func enterPhase(_ id: String, substate: MechanicSubstate? = nil) {
        phase = PhaseCursor(phaseID: id, substate: substate)
    }

    /// Order-stable hashing: dictionaries hash over sorted keys so that two
    /// equal states hash equally regardless of dictionary layout.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rng)
        hasher.combine(matchVars)
        hasher.combine(dealVars)
        hasher.combine(zones)
        hasher.combine(knowledge)
        hasher.combine(dealIndex)
        hasher.combine(dealer)
        hasher.combine(phase)
        hasher.combine(history.count)
        hasher.combine(history)
        hasher.combine(recentEvents)
        hasher.combine(version)
    }

    public static func == (lhs: GameState, rhs: GameState) -> Bool {
        lhs.rng == rhs.rng
            && lhs.matchVars == rhs.matchVars
            && lhs.dealVars == rhs.dealVars
            && lhs.zones == rhs.zones
            && lhs.knowledge == rhs.knowledge
            && lhs.dealIndex == rhs.dealIndex
            && lhs.dealer == rhs.dealer
            && lhs.phase == rhs.phase
            && lhs.history == rhs.history
            && lhs.recentEvents == rhs.recentEvents
            && lhs.version == rhs.version
    }
}
