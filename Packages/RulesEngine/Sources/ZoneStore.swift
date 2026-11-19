// Zones and state (ARCHITECTURE §9.1). A zone is a keyed, ordered list of
// card instances. ZoneStore enforces card conservation: every CardID is in
// exactly one zone at all times.
// Internal dictionaries use scalar keys (String / UInt64) so that canonical
// JSON encoding with `.sortedKeys` is deterministic across platforms
// (required by replay hashing, §10.4).

import CardModel

/// Identifies a zone: whose scope it belongs to and its ruleset-defined id.
public struct ZoneKey: Hashable, Codable, Sendable {
    public enum Scope: String, Codable, Sendable {
        case seat
        case team
        case shared
    }

    public let scope: Scope
    /// Seat/team index for seat- and team-scoped zones; 0 for shared zones.
    public let owner: Int
    public let id: String

    public init(scope: Scope, owner: Int = 0, id: String) {
        self.scope = scope
        self.owner = owner
        self.id = id
    }

    /// Canonical storage key: "scope:owner:id".
    var storageKey: String { "\(scope.rawValue):\(owner):\(id)" }

    init(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 2)
        scope = parts.count > 0 ? Scope(rawValue: String(parts[0])) ?? .shared : .shared
        owner = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        id = parts.count > 2 ? String(parts[2]) : ""
    }
}

/// A physical card in play: which copy (CardID) is which face.
public struct CardInstance: Codable, Hashable, Sendable {
    public let id: CardID
    public let face: CardFace

    public init(id: CardID, face: CardFace) {
        self.id = id
        self.face = face
    }
}

public enum ZoneStoreError: Error, Equatable, Sendable {
    /// Moving a card that is not in the source zone.
    case cardNotInSource(ZoneKey, CardID)
    /// The destination zone is at capacity.
    case destinationFull(ZoneKey)
    /// The destination zone is unknown.
    case unknownZone(ZoneKey)
}

public struct ZoneStore: Codable, Hashable, Sendable {
    /// Zone storage keyed canonically by "scope:owner:id".
    private var zoneMap: [String: [CardInstance]] = [:]
    /// Conservation index: every CardID currently in play maps to its zone.
    private var location: [UInt64: String] = [:]
    /// Declared capacities (nil = unbounded).
    private var capacities: [String: Int] = [:]

    public init() {}

    /// Declare a zone before use (ruleset setup). Re-declaring resets it.
    public mutating func declare(_ key: ZoneKey, capacity: Int? = nil) {
        zoneMap[key.storageKey] = []
        capacities[key.storageKey] = capacity
        // Remove any stale locations pointing at this zone's cards.
        location = location.filter { $0.value != key.storageKey }
    }

    /// Declare a zone only if it does not exist yet (idempotent; never wipes).
    public mutating func ensureDeclared(_ key: ZoneKey, capacity: Int? = nil) {
        if zoneMap[key.storageKey] == nil { declare(key, capacity: capacity) }
    }

    public func cards(in key: ZoneKey) -> [CardInstance] { zoneMap[key.storageKey] ?? [] }

    public func zoneOf(_ id: CardID) -> ZoneKey? {
        location[UInt64(id.raw)].map { ZoneKey(storageKey: $0) }
    }

    /// Total card instances across every zone. Host-side diagnostics only
    /// (the P2.8 simulator's conservation invariant); counts leak no faces.
    public var totalCardCount: Int { location.count }

    /// Move one card instance from one zone to another, appending at the
    /// destination (top = end of the array). Conservation is enforced here:
    /// a CardID is always in exactly one zone.
    public mutating func move(_ id: CardID, from source: ZoneKey, to destination: ZoneKey) throws(ZoneStoreError) {
        let sourceKey = source.storageKey
        let destinationKey = destination.storageKey
        guard zoneMap[destinationKey] != nil else { throw .unknownZone(destination) }
        guard var list = zoneMap[sourceKey], let index = list.firstIndex(where: { $0.id == id }) else {
            throw .cardNotInSource(source, id)
        }
        if let cap = capacities[destinationKey], zoneMap[destinationKey]!.count >= cap, destinationKey != sourceKey {
            throw .destinationFull(destination)
        }
        var destinationList = zoneMap[destinationKey]!
        destinationList.append(list[index])
        zoneMap[destinationKey] = destinationList
        list.remove(at: index)
        zoneMap[sourceKey] = list
        location[UInt64(id.raw)] = destinationKey
    }

    /// Move several instances in order.
    public mutating func move(_ ids: [CardID], from source: ZoneKey, to destination: ZoneKey) throws(ZoneStoreError) {
        for id in ids { try move(id, from: source, to: destination) }
    }

    /// Place a card into a zone from outside play (deal setup, redeal).
    public mutating func place(_ instance: CardInstance, in key: ZoneKey) throws(ZoneStoreError) {
        let keyString = key.storageKey
        guard zoneMap[keyString] != nil else { throw .unknownZone(key) }
        if let cap = capacities[keyString], zoneMap[keyString]!.count >= cap {
            throw .destinationFull(key)
        }
        if let current = location[UInt64(instance.id.raw)] {
            zoneMap[current]?.removeAll { $0.id == instance.id }
        }
        zoneMap[keyString]!.append(instance)
        location[UInt64(instance.id.raw)] = keyString
    }

    /// Remove and return the top card (end of the array) of a zone.
    public mutating func popTop(from key: ZoneKey) throws(ZoneStoreError) -> CardInstance? {
        let keyString = key.storageKey
        guard var list = zoneMap[keyString], !list.isEmpty else {
            if zoneMap[keyString] == nil { throw .unknownZone(key) }
            return nil
        }
        let instance = list.removeLast()
        zoneMap[keyString] = list
        location.removeValue(forKey: UInt64(instance.id.raw))
        return instance
    }

    /// Shuffle a zone in place (the shuffle comes from the engine's RNG, so
    /// determinism is preserved).
    public mutating func shuffleZone(_ key: ZoneKey, using rng: inout SeededRNG) {
        guard var list = zoneMap[key.storageKey], list.count > 1 else { return }
        rng.shuffle(&list)
        zoneMap[key.storageKey] = list
    }

    /// Every instance currently in play.
    public var allInstances: [CardInstance] {
        zoneMap.values.flatMap { $0 }
    }

    /// All declared zones with their contents.
    public var zones: [ZoneKey: [CardInstance]] {
        var result: [ZoneKey: [CardInstance]] = [:]
        for (keyString, cards) in zoneMap {
            result[ZoneKey(storageKey: keyString)] = cards
        }
        return result
    }

    // Canonical Codable: `location` (UInt64 keys) is emitted as a sorted
    // [id, zone] array; the String-keyed maps rely on `.sortedKeys`, which
    // sorts String-keyed dictionaries. JSON encoding must be deterministic
    // across platforms (replay hashing, §10.4).

    private enum CodingKeys: String, CodingKey {
        case zoneMap
        case location
        case capacities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoneMap = try container.decode([String: [CardInstance]].self, forKey: .zoneMap)
        capacities = try container.decode([String: Int].self, forKey: .capacities)
        let pairs = try container.decode([[String]].self, forKey: .location)
        for pair in pairs where pair.count == 2 {
            location[UInt64(pair[0]) ?? 0] = pair[1]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(zoneMap, forKey: .zoneMap)
        try container.encode(capacities, forKey: .capacities)
        let sorted = location.sorted { $0.key < $1.key }.map { [String($0.key), $0.value] }
        try container.encode(sorted, forKey: .location)
    }
}
