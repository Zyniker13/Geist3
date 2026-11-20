/// Everything the evaluator needs beyond the expression itself.
///
/// Data the engine owns — seat order, zone contents, variable stores,
/// the trick snapshot — is supplied here as plain values; reads that
/// depend on hidden state (`holderOf`, `choice`) are closures the host
/// fills in. The evaluator is deterministic: the same environment and
/// expression always produce the same value.
public struct EvaluationEnvironment: Sendable {
    /// Seats in play order (§7.3 `seats()`); `left`/`right`/`partner`
    /// arithmetic follows this order.
    public var seats: [Value]
    /// Seats currently in the game (`players.active`, `nextActive`).
    public var activeSeats: Set<String>
    /// Teams in play order (§7.3 `teams()`).
    public var teams: [Value]
    /// Which team each seat belongs to (`team(s)`).
    public var teamOfSeat: [String: String]
    /// Zone contents by id, full state (host evaluation; §7.5).
    public var zoneContents: [String: [Value]]
    /// Zone read with an owner filter (`zone(id, seat | team)`).
    public var zoneReader: @Sendable (String, Value?) -> [Value]
    /// `holderOf(faceId)`: the seat holding the face-up card, or null.
    public var holderOf: @Sendable (String) -> Value
    /// `tricksWon(team | seat)`: tricks taken so far.
    public var tricksWon: @Sendable (Value) -> Int64
    /// `playedBy(s)`: the cards the seat has played to the current trick.
    public var playedBy: @Sendable (String) -> [Value]
    /// `choice(id, seat)`: a host-mediated selection (§7.5 host-only).
    public var choice: @Sendable (String, String) -> Value
    /// `dealtHands()`: the cards each seat was dealt this deal.
    public var dealtHands: @Sendable () -> [Value]

    /// Option values by id (`options.<id>`).
    public var optionValues: [String: Value]
    /// Contextual bindings (§7.3): `dealer`, `seat`, `c`, `s`, `t`,
    /// `call`, `param`, `cards`, `isCrib`, `awardee`, plus any the
    /// mechanic adds.
    public var contextual: [String: Value]
    /// The trick snapshot (`trick.*`); absent fields are `null`.
    public var trick: TrickSnapshot
    /// `players.count` / `players.active`.
    public var playersCount: Int
    /// `deal.index`: 0-based deal number in the match.
    public var dealIndex: Int
    /// Non-indexed match- and deal-scoped variables by name.
    public var plainVars: [VarRef: Value]
    /// Per-seat and per-team variables as positional lists, ordered by the
    /// variable's index domain: the seat order for seat scopes, the team
    /// order for team scopes (§7.3). Match- and deal-scoped variables read
    /// as single values out of `plainVars`.
    public var indexedVars: [VarRef: [Value]]
    /// Native function implementations (§5.8), keyed by dotted name.
    public var natives: [String: @Sendable ([Value]) throws(EvaluationFault) -> Value]

    /// Rank orders by name (`rankIndex`); the engine fills this from the
    /// ruleset's declared orders.
    public var orders: [String: [String]]

    /// The trick fields of §7.3.
    public struct TrickSnapshot: Sendable {
        public var number: Value
        public var leader: Value
        public var cards: Value
        public var ledSuit: Value
        public var winner: Value

        public init(
            number: Value = .null, leader: Value = .null, cards: Value = .list([]),
            ledSuit: Value = .null, winner: Value = .null
        ) {
            self.number = number
            self.leader = leader
            self.cards = cards
            self.ledSuit = ledSuit
            self.winner = winner
        }
    }

    public init(
        seats: [Value] = [], activeSeats: Set<String> = [], teams: [Value] = [],
        teamOfSeat: [String: String] = [:], zoneContents: [String: [Value]] = [:],
        zoneReader: @escaping @Sendable (String, Value?) -> [Value] = { _, _ in [] },
        holderOf: @escaping @Sendable (String) -> Value = { _ in .null },
        tricksWon: @escaping @Sendable (Value) -> Int64 = { _ in 0 },
        playedBy: @escaping @Sendable (String) -> [Value] = { _ in [] },
        choice: @escaping @Sendable (String, String) -> Value = { _, _ in .null },
        dealtHands: @escaping @Sendable () -> [Value] = { [] },
        optionValues: [String: Value] = [:],
        contextual: [String: Value] = [:], trick: TrickSnapshot = TrickSnapshot(),
        playersCount: Int = 0, dealIndex: Int = 0,
        plainVars: [VarRef: Value] = [:], indexedVars: [VarRef: [Value]] = [:],
        orders: [String: [String]] = [:],
        natives: [String: @Sendable ([Value]) throws(EvaluationFault) -> Value] = [:]
    ) {
        self.seats = seats
        self.activeSeats = activeSeats
        self.teams = teams
        self.teamOfSeat = teamOfSeat
        self.zoneContents = zoneContents
        self.zoneReader = zoneReader
        self.holderOf = holderOf
        self.tricksWon = tricksWon
        self.playedBy = playedBy
        self.choice = choice
        self.dealtHands = dealtHands
        self.optionValues = optionValues
        self.contextual = contextual
        self.trick = trick
        self.playersCount = playersCount
        self.dealIndex = dealIndex
        self.plainVars = plainVars
        self.indexedVars = indexedVars
        self.orders = orders
        self.natives = natives
    }
}
