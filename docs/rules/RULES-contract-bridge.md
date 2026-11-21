# Contract Bridge (Rubber) — Rules (`contract-bridge.rubber` 1.0.0)

The rules of Parlor's `contract-bridge.rubber` ruleset, written out in full.
Every rule carries its ruleset rule ID (`BRG-x.y`); those IDs are the
contract between this document, the ruleset JSON
(`docs/plan/rulesets/contract-bridge.rubber.ruleset.json`), and the
conformance suites (`docs/CONFORMANCE.md`). The prose here is original to
Parlor; the cited sources describe the traditional game this ruleset
formalizes, and no text is copied from them.

**Sources.** Primary: [Pagat — Rubber Bridge](https://www.pagat.com/auctionwhist/bridge.html)
(the ruleset's `sources` entry `pagat`). The scored values in §5 follow the
standard rubber tables as implemented by the `bridge.score` native
(`StandardNatives+Bridge.swift`), which itself follows the penalty and
bonus schedules of the published laws: the
[ACBL Laws of Rubber Bridge](https://cdn.acbl.org/wp-content/uploads/2015/02/Laws-of-Rubber-Bridge.pdf)
(`acbl-rubber`) and the
[WBF Laws of Duplicate Bridge (2017)](https://www.worldbridge.org/regulations/2017-laws-of-duplicate-bridge/)
(`wbf-2017`), the latter cited where its doubled-penalty schedule is the
one implemented.

**Table.** Four players in two partnerships (dealer's side versus the
opposition), one French 52-card deck, natural rank order (deuce low, ace
high). The strain order for auctions is clubs, diamonds, hearts, spades,
then no trump.

## 1. The deal

**BRG-1.1 — Partnerships and the deal.** The four players sit as two
partnerships; the deck is dealt out in full, thirteen cards to each player,
face down. One player is the dealer for the deal; dealership rotates
leftwards deal by deal.
(Implemented by the `deal` phase, 13-card packets; source: Pagat — Rubber
Bridge, "Deal".)

## 2. The auction

**BRG-2.1 — Calls.** The dealer calls first and the turn passes clockwise.
On each turn a player makes exactly one call: a bid, a pass, a double, or a
redouble. The auction proceeds until it ends under BRG-2.4.
(Implemented by the `auction.ladder` phase's call menu; source: Pagat —
Rubber Bridge, "The Bidding".)

**BRG-2.2 — Bids and their ranking.** A bid names a level from 1 to 7 —
the number of tricks over six that the bidder's side undertakes to take —
together with a strain (a suit, or no trump). Each new bid must outrank the
previous one: first on level, and on equal level by the strain order
clubs < diamonds < hearts < spades < no trump.
(Implemented by the ladder's level/strain ranking; source: Pagat — Rubber
Bridge, "The Bidding".)

**BRG-2.3 — Double and redouble.** A side may double the opponents'
current bid, and only that bid, and only if it is not already doubled. The
side that made the doubled bid may redouble it, and only if it has not
already been redoubled. Either new bid by any side resets both multipliers.
(Implemented by the ladder's `double`/`redouble` calls with the
`doubled`/`redoubled` flags; source: Pagat — Rubber Bridge, "Doubles";
WBF 2017 laws for the call-legality sequence.)

**BRG-2.4 — Ending the auction.** The auction ends after three
consecutive passes that follow a bid. The last bid — with its double or
redouble state — becomes the final contract.
(Implemented by the ladder's `consecutivePassesAfterBid: 3` end rule;
source: Pagat — Rubber Bridge, "The Bidding".)

**BRG-2.5 — The declarer.** The declarer is the player of the side that
won the auction who was **first to name the final strain** during the
auction (whether or not that player made the final bid). The declarer
plays both their own hand and their partner's.
(Implemented by the ladder's declarer result, ruled by the
`firstOfWinningSideToNameStrain` definition; source: Pagat — Rubber
Bridge, "Play".)

**BRG-2.6 — Thrown-in deals.** If all four players pass at their first
turns, no contract exists and the deal is thrown in. The `passOut` option
(default `redealNextDealer`) re-deals to the next dealer; the alternative
re-deals with the same dealer.
(Implemented by the ladder's `allPass` action; source: Pagat — Rubber
Bridge, "Passed-out hands".)

## 3. Play

**BRG-3.1 — The opening lead.** The player to the declarer's left leads
any card to the first trick. No card may be played before the auction has
ended and the dummy has not yet been exposed.
(Implemented by `firstLeader: left(deal.declarer, 1)`; source: Pagat —
Rubber Bridge, "Play".)

**BRG-3.2 — The dummy.** After the opening lead has been made, the
declarer's partner — the dummy — spreads their hand face up on the table,
and it stays visible to all. The declarer plays the cards of both hands:
the dummy plays no cards of their own volition and takes no decisions.
The dummy's hand is hidden until the opening lead is complete.
(Implemented by the trick-play phase's `dummy` block with
`revealAfter: openingLead`, `controlledBy: deal.declarer`; source: Pagat —
Rubber Bridge, "Play".)

## 4. Play rules

**BRG-4.1 — Following suit.** You must follow the suit led if you can; only
if you hold no card of that suit may you play any card, including a trump.
(Implemented by the trick-play phase's `follow.mustFollow`; source: Pagat —
Rubber Bridge, "Play".)

**BRG-4.2 — Winning a trick.** The highest trump played to the trick wins
it; if no trump was played, the highest card of the suit led wins. The
winner of a trick leads to the next.
(Implemented by `winner: highestTrumpElseLedSuit`, `nextLeader: winner`;
source: Pagat — Rubber Bridge, "Play".)

**BRG-4.6 — Claims.** With the `claims` option (default on), the declarer
may claim the remaining tricks by stating a number and exposing their
remaining cards. A defender may accept the claim, ending play of the deal
at the claimed count, or reject it and play on; play then continues and
the claim has no further effect.
(Implemented by the trick-play phase's `claims` block, claimed by the
declarer, accepted by the defenders; source: Pagat — Rubber Bridge,
"Claims"; WBF 2017 laws for the claim procedure.)

## 5. Scoring

All scored amounts below are computed by the `bridge.score` native; the
rule IDs tag the effects that apply its results to the match store.

**BRG-5.1 — Trick points and games.** A side that makes its contract scores
trick points for the contracted tricks **below the line**: 20 per trick for
a minor-suit contract (clubs, diamonds), 30 per trick for a major (hearts,
spades), and 40 for the first notrump trick plus 30 for each further one.
Doubling multiplies the trick score by two and redoubling by four. When a
side's below-the-line total reaches 100 or more in the rubber, that side
has won a **game**: its below-the-line score moves above the line and the
count starts again. Two games won in a rubber end the rubber (BRG-5.5).
(Implemented by the `score` phase's `match.below`/`match.games` effects;
source: Pagat — Rubber Bridge, "Scoring"; ACBL rubber laws.)

**BRG-5.2 — Above-the-line scores.** Everything else scores **above the
line**: overtricks (at the strain's trick rate undoubled; 100 each doubled
and 200 each redoubled when not vulnerable, 200 and 400 when vulnerable),
slam bonuses (500 not vulnerable or 750 vulnerable for a small slam; 1000
or 1500 for a grand slam), the insult of 50 for making a doubled contract
or 100 a redoubled one, and the penalty the declaring side pays for
undertricks (50 per trick not vulnerable or 100 when vulnerable,
undoubled; when doubled, the escalating schedule of the published laws,
redoubled doubling it again). Overtrick and undertrick amounts scored for
or by the defenders are added above the line for the defending side.
(Implemented by the `score` phase's `match.above` effects; source: Pagat —
Rubber Bridge, "Scoring"; WBF 2017 laws for doubled undertricks.)

**BRG-5.5 — The rubber.** The first side to win two games wins the rubber
and scores a rubber bonus above the line: 700 if the losers won no game in
the rubber, otherwise 500. The match ends when a side has won two games;
the side with the higher above-the-line total wins.
(Implemented by the `score` phase's rubber-bonus effect and the ruleset
`end` block, rank `descending(match.above)`, ties `shared`; source: Pagat —
Rubber Bridge, "Rubber bonus".)

**BRG-5.6 — Honors.** With the `honors` option (default on), after the
play of a deal each partnership scores an honors bonus above the line for
honour cards held in one hand: 100 for four trump honours (aces, kings,
queens, jacks of the trump suit), 150 for all five, and 150 for all four
aces when the contract was in no trump.
(Implemented by the `score` phase's honors effect using the
`bridge.honors` native; source: Pagat — Rubber Bridge, "Honors".)

## Options summary

| Option | Type | Default | Rule |
| --- | --- | --- | --- |
| `honors` | bool | on | BRG-5.6 |
| `passOut` | enum | `redealNextDealer` | BRG-2.6 |
| `claims` | bool | on | BRG-4.6 |

## Defaults chosen while writing these rules

- The doubled-undertrick schedule implemented in `bridge.score` follows the
  WBF 2017 laws' table (the same schedule rubber bridge uses); redoubled
  penalties double the doubled ones. Recorded here because the laws' own
  prose is not copied into this repository.
- A side that wins the rubber with the opponents at zero games scores 700
  above the line, otherwise 500; these are the standard rubber bonuses and
  are pinned by the conformance suite's hand-built expectations.
