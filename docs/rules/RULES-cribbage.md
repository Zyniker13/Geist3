# Cribbage (Six-Card) — Rules (`cribbage.six-card` 1.0.0)

The rules of Parlor's `cribbage.six-card` ruleset, written out in full.
Every rule carries its ruleset rule ID (`CRB-x.y`); those IDs are the
contract between this document, the ruleset JSON
(`docs/plan/rulesets/cribbage.six-card.ruleset.json`), and the conformance
suites (`docs/CONFORMANCE.md`). The prose here is original to Parlor; the
cited sources describe the traditional game this ruleset formalizes, and no
text is copied from them.

**Sources.** Primary: the
[American Cribbage Congress 2025 Rulebook](https://cribbage.org/NewSite/rules/rulebook_2025.pdf)
(the ruleset's `sources` entry `acc`). Secondary:
[Pagat — Cribbage (six cards)](https://www.pagat.com/adders/crib6.html)
(`pagat`).

**Table.** Two players, one French 52-card deck, natural rank order with
aces low in counting (a run may not cross from king to ace). Face cards
count 10 in play and in hands.

## 1. The deal

**CRB-1.1 — Six cards each.** The dealer gives each player six cards, dealt
alternately one or a few at a time; each player's hand stays hidden from
the other. The undealt remainder is set aside as the stock.
(Implemented by the `deal` phase, 6-card packets to each hand; source: ACC
rulebook, "Deal"; Pagat — Cribbage, "Deal".)

## 2. The crib

**CRB-2.1 — Laying away.** After looking at their six cards, each player
lays away two cards face down. The four laid-away cards form the **crib**,
a second four-card hand that is counted later by the dealer alone. Neither
player sees the other's lay-away, and the crib is hidden until the show.
The crib belongs to the dealer of the deal.
(Implemented by the `exchange.discardTo` phase, `count: 2`, `from: hand`,
`to: crib`, simultaneous, revealed to nobody; source: ACC rulebook, "The
crib"; Pagat — Cribbage, "The Crib".)

## 3. The starter

**CRB-3.1 — The cut.** After the lay-away, the player to the dealer's left
in a two-player game — the non-dealer, or *pone* — cuts the stock, and the
top card of the lower packet is turned face up. That card, the **starter**,
counts as a fifth card with every hand and with the crib during the show.
(Implemented by the `reveal.starter` phase, `cutBy: pone()`,
`minCutDepth: 4`; source: ACC rulebook, "The cut"; Pagat — Cribbage, "The
starter".)

**CRB-3.2 — His heels.** If the turned starter is a jack, the dealer pegs
2 points at once, called *his heels*.
(Implemented by the starter phase's `after` effect adding 2 to the
dealer's score; source: ACC rulebook, "His heels".)

## 4. Pegging (play of the cards)

**CRB-4.1 — The running count.** Beginning with the non-dealer, the players
play cards alternately from their hands face up in front of themselves,
each announcing the running total of card values. Aces count 1, face cards
10. The total may never exceed 31; a player who has no card that keeps the
total at or under 31 cannot play.
(Implemented by the `count-play` phase with `limit: 31` and the
`valueOf` definition; source: ACC rulebook, "Pegging"; Pagat — Cribbage,
"Play".)

**CRB-4.2 — Go.** A player who cannot play says *go*; if the opponent can
still play, the opponent plays on and may score, and a player who cannot
play does not play again while the run continues. When no player can play,
the player of the last card played pegs 1 point for the go, and a new run
begins with the opponent of the last player as leader. Playing the last
card of a run by reaching exactly 31 scores 2 points instead.
(Implemented by the count-play phase's go handling with
`go.lastCardPoints: 1` and `go.exactLimitPoints: 2`; source: ACC rulebook,
"Scoring during play".)

**CRB-4.3 — Points in play.** During pegging, a player scores 2 for each
fifteen they make (a running total of exactly 15), 2 for a pair (and 6 for
three of a kind, 12 for four, as each pair among the same rank scores), and
the length of each run their card completes (1 point per card in the run,
counting duplicate cards once each in the run's window).
(Implemented by the count-play phase's `pointsOnPlay` expression using the
`cribbage.pegPoints` native; source: ACC rulebook, "Scoring during play".)

## 5. The show

**CRB-5.1 — Order of counting.** When the pegging ends, players count their
hands aloud and peg them in strict order: the non-dealer first, then the
dealer, then the dealer's crib — each hand counted with the starter added
to it. Each player's played cards return to their hand before the show.
(Implemented by the `show` phase's `order` entries and the count-play
phase's `returnCards: true`; source: ACC rulebook, "The show".)

**CRB-5.2 — Hand values.** A counted hand scores: 2 points for each
distinct combination of cards summing to fifteen; 2 for every pair of equal
ranks (6 for three of a kind, 12 for four); 1 point per card for each run
of three or more consecutive ranks, scoring once for every way the run's
ranks can be taken; a four-card flush 4 (all four hand cards of one suit,
never counting the starter) and a five-card flush 5 (all four hand cards
and the starter of one suit — possible only in the crib); and 1 point
*nibs* for a jack in the hand of the same suit as the starter.
(Implemented by the `show` phase's `points` expression using the
`cribbage.handScore` native; source: ACC rulebook, "Scoring the hands".)

**CRB-5.4 — Muggins.** With the `muggins` option (default off), when a
player has counted their hand and pegged fewer points than it contains,
the first opponent to notice may claim the missed points for themselves.
(Manual counting, the companion option on the same rule, is declared by
the schema but not supported in Engine 1.0 and faults if enabled.)
(Declared by the ruleset's options and reserved by the `show` mechanic;
source: ACC rulebook, "Muggins".)

## 6. Winning

**CRB-6.1 — The target.** The first player whose pegged score reaches the
`target` option (default 121, or 61 for a short game) wins immediately —
the win takes effect as soon as it is pegged, even in the middle of
pegging or of the show.
(Implemented by the ruleset `end` block with continuous checking, rank
`descending(match.score)`, ties `impossible`; source: ACC rulebook,
"Length of game".)

**CRB-6.2 — Skunks.** With the `skunks` option (default on), when the match
ends a loser who has not passed 90 points in a 121-point game (46 in a
61-point game) is *skunked*, worth a double win to the victor; the table
option gates whether the skunk is announced.
(Implemented by the `end` block's match effect emitting the `skunk` event
at the 91/46 thresholds — a score below 91 is a score that has not passed
90; source: ACC rulebook, "Skunks".)

## Options summary

| Option | Type | Default | Rule |
| --- | --- | --- | --- |
| `target` | enum | 121 | CRB-6.1 |
| `muggins` | bool | off | CRB-5.4 |
| `manualCounting` | bool | off | CRB-5.4 (faults in Engine 1.0) |
| `skunks` | bool | on | CRB-6.2 |

## Defaults chosen while writing these rules

- The skunk line is expressed in the rule text as "has not passed 90" in a
  121-point game; the implementation compares against a score below 91,
  which is the same condition. The 61-point game uses 46.
- Muggins is implemented as declared-but-faulting in Engine 1.0: the option
  exists, the rule is documented, and enabling it does not silently change
  scoring until the engine supports claimable missed points.
- The first dealer is chosen by a low-card cut (`setup.firstDealer:
  lowCut`) and thereafter the deal alternates; the starter cut requires at
  least four cards lifted (`minCutDepth: 4`) so a cut of nothing or one
  card is never possible.
