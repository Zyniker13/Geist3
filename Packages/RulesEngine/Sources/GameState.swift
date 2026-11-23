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
    /// Index of the first event of the current deal inside `recentEvents`
    /// (§9.6): events before it belong to the previous deal, whose card
    /// IDs this deal has reassigned — redacting them against the current
    /// knowledge store can name a face the viewer must not see. Event
    /// redaction and observation therefore drop the stale prefix. The
    /// index is maintained by the deal boundary (Engine+Match) and is
    /// engine-internal bookkeeping, not rule state: it is excluded from
    /// hashing and equality (it is a function of the event log and deal
    /// count, not independent state) and nothing in-repo persists
    /// GameState JSON.
    public var firstDealEvent: Int
    public var version: UInt64
    /// Per-phase options set by mechanics (e.g., "passed_0", "passed_1").
    public var phaseOptions: [String: String]

    /// The cards each seat was dealt this deal (§7.5 `dealtHands()`),
    /// recorded by the deal mechanic and cleared with the other deal-scoped
    /// state (§5.7). Host-side only: the redactor builds observations
    /// field-by-field and never copies this into an `Observation`.
    /// Keyed by raw seat (scalar keys encode canonically, §10.4).
    public var dealt: [Int: [CardInstance]]
    /// Last completed trick-play substate of this deal (ADR-0033),
    /// host-side only: kept for score-phase `tricksWon` lookups, never
    /// copied into an `Observation`.
    public var lastPlaySubstate: TrickSubstate?
    /// True once the match end condition fired (§5.8); the host reads
    /// `winners` to close the session.
    public var matchOver: Bool
    /// Winner seats in `end.rank` order; empty while the match runs.
    public var winners: [Seat]

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
        firstDealEvent: Int = 0,
        version: UInt64 = 0,
        phaseOptions: [String: String] = [:],
        dealt: [Int: [CardInstance]] = [:],
        lastPlaySubstate: TrickSubstate? = nil,
        matchOver: Bool = false,
        winners: [Seat] = []
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
        self.firstDealEvent = firstDealEvent
        self.version = version
        self.phaseOptions = phaseOptions
        self.dealt = dealt
        self.lastPlaySubstate = lastPlaySubstate
        self.matchOver = matchOver
        self.winners = winners
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

    /// Auction sub-state (`auction.rounds` / `auction.ladder` share one
    /// record shape; each mechanic owns its case).
    func auctionSubstate() -> AuctionSubstate {
        switch phase.substate {
        case .auctionRounds(let sub), .auctionLadder(let sub): return sub
        default: return AuctionSubstate()
        }
    }

    mutating func setAuctionSubstate(_ sub: AuctionSubstate, ladder: Bool) {
        let state: MechanicSubstate = ladder ? .auctionLadder(sub) : .auctionRounds(sub)
        phase = PhaseCursor(phaseID: phase.phaseID, substate: state)
    }

    /// Show sub-state (ADR-0032): the index of the next `show.order`
    /// entry to count, so the show runs one step per engine loop pass and
    /// the continuous end check fires between entries (§5.3).
    func showSubstate() -> ShowSubstate? {
        if case .show(let sub) = phase.substate { return sub }
        return nil
    }

    mutating func setShowSubstate(_ sub: ShowSubstate) {
        phase = PhaseCursor(phaseID: phase.phaseID, substate: .show(sub))
    }

    /// Completed play record of this deal (ADR-0033): a copy of the last
    /// trick-play substate, kept after the play phase ends so score-phase
    /// expressions (`tricksWon`, §7.3 builtins) can still read the deal's
    /// cumulative trick counts. Cleared on the per-deal reset.
    public func lastPlayTrick() -> TrickSubstate? { lastPlaySubstate }

    public mutating func setLastPlayTrick(_ sub: TrickSubstate) {
        lastPlaySubstate = sub
    }

    /// Advance to a phase and reset its mechanic sub-state.
    mutating func enterPhase(_ id: String, substate: MechanicSubstate? = nil) {
        phase = PhaseCursor(phaseID: id, substate: substate)
    }

    // MARK: - Phase options

    func phaseOption(_ key: String) -> String? {
        phaseOptions[key]
    }

    mutating func setPhaseOption(_ key: String, value: String) {
        phaseOptions[key] = value
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
        hasher.combine(phaseOptions)
        hasher.combine(matchOver)
        hasher.combine(winners)
        if let lastPlaySubstate { hasher.combine(lastPlaySubstate) }
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
            && lhs.phaseOptions == rhs.phaseOptions
            && lhs.matchOver == rhs.matchOver
            && lhs.winners == rhs.winners
            && lhs.lastPlaySubstate == rhs.lastPlaySubstate
    }
}
