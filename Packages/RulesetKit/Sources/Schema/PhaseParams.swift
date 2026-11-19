// PhaseParams dispatch: typed payload of one phase, keyed by the phase's
// `mechanic` id. Unknown mechanic ids are preserved verbatim (`unknown`) so
// the validator can flag them without the loader losing data.

import Foundation

public enum PhaseParams: Equatable, Sendable {
    case deal(DealParams)
    case auctionLadder(AuctionLadderParams)
    case auctionRounds(AuctionRoundsParams)
    case exchangePass(ExchangePassParams)
    case exchangeKitty(ExchangeKittyParams)
    case exchangeDiscardTo(ExchangeDiscardToParams)
    case revealStarter(RevealStarterParams)
    case trickPlay(TrickPlayParams)
    case countPlay(CountPlayParams)
    case show(ShowParams)
    case score(ScoreParams)
    case unknown(mechanic: String, json: JSON)

    public static let knownMechanics: [String] = [
        "deal", "auction.ladder", "auction.rounds",
        "exchange.pass", "exchange.kitty", "exchange.discardTo",
        "reveal.starter", "trick-play", "count-play", "show", "score",
    ]

    /// Decode the phase payload for `mechanic`. Split into two switches so
    /// each stays under the lint complexity bound; the second handles the
    /// auction/exchange families.
    public init(json: JSON, mechanic: String, path: String) throws(SchemaError) {
        switch mechanic {
        case "deal": self = .deal(try DealParams(json: json, path: path))
        case "reveal.starter": self = .revealStarter(try RevealStarterParams(json: json, path: path))
        case "trick-play": self = .trickPlay(try TrickPlayParams(json: json, path: path))
        case "count-play": self = .countPlay(try CountPlayParams(json: json, path: path))
        case "show": self = .show(try ShowParams(json: json, path: path))
        case "score": self = .score(try ScoreParams(json: json, path: path))
        default:
            self = try PhaseParams.auctionOrExchange(mechanic: mechanic, json: json, path: path)
        }
    }

    /// Second dispatch stage: auction and exchange families; anything else is
    /// preserved verbatim as `unknown`.
    private static func auctionOrExchange(
        mechanic: String, json: JSON, path: String
    ) throws(SchemaError) -> PhaseParams {
        switch mechanic {
        case "auction.ladder": return .auctionLadder(try AuctionLadderParams(json: json, path: path))
        case "auction.rounds": return .auctionRounds(try AuctionRoundsParams(json: json, path: path))
        case "exchange.pass": return .exchangePass(try ExchangePassParams(json: json, path: path))
        case "exchange.kitty": return .exchangeKitty(try ExchangeKittyParams(json: json, path: path))
        case "exchange.discardTo":
            return .exchangeDiscardTo(try ExchangeDiscardToParams(json: json, path: path))
        default: return .unknown(mechanic: mechanic, json: json)
        }
    }

    public var mechanic: String {
        switch self {
        case .deal: return "deal"
        case .auctionLadder: return "auction.ladder"
        case .auctionRounds: return "auction.rounds"
        case .exchangePass: return "exchange.pass"
        case .exchangeKitty: return "exchange.kitty"
        case .exchangeDiscardTo: return "exchange.discardTo"
        case .revealStarter: return "reveal.starter"
        case .trickPlay: return "trick-play"
        case .countPlay: return "count-play"
        case .show: return "show"
        case .score: return "score"
        case .unknown(let mechanic, _): return mechanic
        }
    }

    public var json: JSON {
        switch self {
        case .deal(let p): return p.json
        case .auctionLadder(let p): return p.json
        case .auctionRounds(let p): return p.json
        case .exchangePass(let p): return p.json
        case .exchangeKitty(let p): return p.json
        case .exchangeDiscardTo(let p): return p.json
        case .revealStarter(let p): return p.json
        case .trickPlay(let p): return p.json
        case .countPlay(let p): return p.json
        case .show(let p): return p.json
        case .score(let p): return p.json
        case .unknown(_, let json): return json
        }
    }
}
