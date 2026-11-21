# Euchre — Standard Rules (`euchre.standard` 1.0.0)

The rules of Parlor's `euchre.standard` ruleset, written out in full. Every
rule carries its ruleset rule ID (`EUC-x.y`); those IDs are the contract
between this document, the ruleset JSON
(`docs/plan/rulesets/euchre.standard.ruleset.json`), and the conformance
suites (`docs/CONFORMANCE.md`). The prose here is original to Parlor; the
cited sources describe the traditional game this ruleset formalizes, and no
text is copied from them.

**Sources.** Primary: [Pagat — Euchre](https://www.pagat.com/euchre/euchre.html)
(the ruleset's `sources` entry `pagat`). Secondary:
[World Euchre Federation — Official Rules of Euchre](https://www.worldeuchrefederation.com/official-rules-of-euchre)
(`wef`).

**Table.** Four players in fixed partnerships (seats 1 and 3 against seats
2 and 4), one 24-card euchre deck (nines up through aces), natural order
within suits.

## 1. The deal

**EUC-1.1 — Five cards and a turn-up.** The dealer gives each player five
cards (in rounds of the traditional pattern) and turns the next card of the
stock face up beside it; the stock's remainder is set aside face down as
the kitty. The turned card is visible to every player.
(Implemented by the `deal` phase with a turn-up packet and the shared
`upcard` zone; source: Pagat — Euchre, "Deal".)

## 2. The auction

**EUC-2.1 — First round: order up or pass.** Beginning with the player to
the dealer's left, each player in turn either passes or orders the dealer
to pick up the turned card. Ordering up makes the turned card's suit trump
at once, and the deal proceeds to EUC-2.2.
(Implemented by the `auction.rounds` phase, round `orderUp`; source: Pagat
— Euchre, "Determining trump".)

**EUC-2.2 — The dealer takes in and discards.** When trump has been ordered
(or, in round two, named), the dealer adds the turned card to their hand
and then lays one card face down on the kitty, restoring their hand to
five. The laid-away card stays known to the dealer alone.
(Implemented by the `exchange.kitty` phase with `take: upcard`,
`discard: 1`, `discardTo: discard`; source: Pagat — Euchre, "Determining
trump".)

**EUC-2.3 — Second round: naming trump.** If every player passes in the
first round, the turned card is turned down onto the discard pile, and the
same rotation begins again: each player in turn either passes or names one
of the other three suits as trump. Naming the suit that was just turned
down is not permitted.
(Implemented by the `auction.rounds` phase, round `nameTrump`, whose
`allowed` guard rejects the discarded suit; source: Pagat — Euchre,
"Determining trump".)

**EUC-2.4 — Passing out and stick the dealer.** If every player passes in
the second round as well, the deal is thrown in and re-dealt by the next
dealer. With the `stickTheDealer` option (default off), the rule changes in
round two: the dealer may not pass and must name a trump suit.
(Implemented by the auction's `allPass` action and the round-two `allowed`
guard on the dealer; source: Pagat — Euchre, "Stick the dealer"; WEF
official rules.)

**EUC-2.5 — Going alone.** With the `goingAlone` option (default on), the
player who makes trump may declare that they are going alone; their partner
sits the deal out and does not play. Going alone is declared by making
trump with the alone form of the making call (`orderUpAlone`, or
`nameAlone` with a named suit); the option gates whether those alone forms
are offered at all.
(Implemented by the auction's alone-flavoured calls writing
`deal.alone`; source: Pagat — Euchre, "Going alone"; WEF official rules.)

## 3. Play

**EUC-3.1 — Bowers.** Within the trump suit the jack of trump (the right
bower) is the highest card, and the jack of the same colour as trump (the
left bower) is the second highest; the left bower counts as a trump for
every purpose, including following suit. Below the two jacks, trump ranks
in natural order (ace high).
(Implemented by the `suitOf` and `strength` rule definitions; source: Pagat
— Euchre, "Rank of cards".)

**EUC-3.2 — Following suit.** You must follow the suit led if you can —
counting the left bower as a card of the trump suit, not of its printed
suit. Only if you cannot follow may you play anything else.
(Implemented by the trick-play phase's `follow.mustFollow` with the
`isLeft`/`suitOf` definitions; source: Pagat — Euchre, "Play"; WEF
official rules.)

**EUC-3.3 — Winning a trick.** The highest trump played to the trick wins
it; if no trump was played, the highest card of the suit led wins.
(Implemented by `winner: highestTrumpElseLedSuit` with the `strength`
definition; source: Pagat — Euchre, "Play".)

**EUC-3.4 — The lead.** The player to the dealer's left leads to the first
trick (skipping a partner who is sitting out a lone hand), and the winner
of each trick leads the next.
(Implemented by `firstLeader: nextActive(left(dealer, 1))` and
`nextLeader: winner`; source: Pagat — Euchre, "Play".)

## 4. Scoring

**EUC-4.1 — Making the contract.** After five tricks, the making side that
took three or four tricks scores 1 point; a side that took all five tricks
scores 2.
(Implemented by the `score` phase's maker branches; source: Pagat —
Euchre, "Scoring".)

**EUC-4.2 — The euchre.** If the making side took fewer than three tricks
they have been euchred, and the defending side scores 2 points, no matter
how many tricks the defenders took.
(Implemented by the `score` phase's defender branch; source: Pagat —
Euchre, "Scoring".)

**EUC-4.3 — The lone march.** A maker who went alone and took all five
tricks scores the `alonePoints` option (default 4) instead of the ordinary
two points for a five-trick march. A lone maker who takes three or four
tricks scores 1 point like any other maker; a lone maker who is euchred
gives the defenders 2 as usual.
(Implemented by the `score` phase's lone branch; source: Pagat — Euchre,
"Going alone".)

## 5. Ending the match

**EUC-5.1 — Target.** The first partnership whose score reaches the
`target` option (default 10 points) wins the match.
(Implemented by the ruleset `end` block, rank `descending(match.score)`,
ties `shared`; source: Pagat — Euchre, "Scoring".)

## Options summary

| Option | Type | Default | Rule |
| --- | --- | --- | --- |
| `stickTheDealer` | bool | off | EUC-2.4 |
| `goingAlone` | bool | on | EUC-2.5 |
| `alonePoints` | int | 4 | EUC-4.3 |
| `target` | int | 10 | EUC-5.1 |

## Defaults chosen while writing these rules

- Passing out twice re-deals to the **next** dealer by default; the
  `passOut` option can hold the deal with the same dealer instead. Both
  conventions are common; the option makes the choice explicit.
- The kitty's own contents remain hidden for the rest of the deal: the
  laid-away card is known only to the dealer (the zone is declared with
  visibility `none`), matching the mainstream convention rather than the
  regional "show the kitty" custom.
