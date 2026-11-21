# Hearts — Standard Rules (`hearts.standard` 1.0.0)

The rules of Parlor's `hearts.standard` ruleset, written out in full. Every
rule carries its ruleset rule ID (`HRT-x.y`); those IDs are the contract
between this document, the ruleset JSON
(`docs/plan/rulesets/hearts.standard.ruleset.json`), and the conformance
suites (`docs/CONFORMANCE.md`). The prose here is original to Parlor; the
cited sources describe the traditional game this ruleset formalizes, and no
text is copied from them.

**Sources.** Primary: [Pagat — Hearts](https://www.pagat.com/reverse/hearts.html)
(the ruleset's `sources` entry `pagat`). Context on the game's popularity:
[YouGov — How Americans feel about 30 card games](https://yougov.com/en-us/articles/45795-how-americans-feel-about-30-card-games).

**Table.** Four players, no partnerships, one French 52-card deck, natural
rank order (deuce low, ace high). No trump suit is ever fixed.

## 1. The deal

**HRT-1.1 — Thirteen cards each.** The deck is shuffled and dealt out in
full: each of the four players receives thirteen cards, dealt face down to
their hand. There is no kitty, widow, or stock; every card is in play.
(Implemented by the `deal` phase; source: Pagat — Hearts, "Deal".)

## 2. The pass

**HRT-2.1 — Passing direction.** Before the first trick of a deal, each
player selects cards from their hand and passes them to another player, all
simultaneously. The direction rotates by deal number with the standard
schedule left, right, across, and then a hold deal with no pass; the
`passSchedule` table option selects the schedule (default
`leftRightAcrossHold`). On a hold deal the pass phase is skipped entirely.
(Implemented by the `exchange.pass` phase with `target:
left(seat, passOffset())`; source: Pagat — Hearts, "Pass".)

**HRT-2.2 — Blind pass.** The number of cards passed is the `passCount`
option (default 3, range 1–4). Each player commits their pass before seeing
any card returned: the passes are staged privately and delivered only once
every player has passed, and only the recipient learns which cards they
received (`revealTo: recipient`). You may not look at what you are getting
before choosing what to give.
(Implemented by the `exchange.pass` phase's simultaneous staging;
source: Pagat — Hearts, "Pass".)

## 3. Play

**HRT-3.1 — First lead.** The holder of the two of clubs leads it to the
first trick. (Implemented by `firstLeader: holderOf('2C')`; source: Pagat —
Hearts, "Play".)

**HRT-3.2 — Following suit.** You must follow the suit led if you can. Only
if you hold no card of the suit led may you play anything else; there is no
trump, so a discard can never win the trick. (Implemented by the trick-play
phase's `follow.mustFollow`; source: Pagat — Hearts, "Play".)

**HRT-3.3 — No points on the first trick.** With the `noPointsFirstTrick`
option (default on), you may not play a penalty card — a heart or the queen
of spades — to the first trick unless your hand holds nothing else. The
guard is a play-time restriction with an `otherwise: any` fallback, so a
hand of only points may still shed them.
(Implemented by the trick-play phase's `playAllowed`; source: Pagat —
Hearts, "Hearts" and house variations.)

**HRT-3.4 — Breaking hearts.** With the `breakingHearts` option (default
on), a heart may not be led until hearts are broken — that is, until a
heart (or, with the `queenBreaksHearts` option, default on, the queen of
spades) has been played to a trick. A player whose entire hand is hearts
may lead a heart despite the restriction.
(Implemented by the trick-play phase's `leadAllowed` and the
`onCardPlayed` effect that sets `deal.heartsBroken`; source: Pagat —
Hearts, "Hearts".)

**HRT-3.5 — Winning a trick.** The highest card played of the suit led wins
the trick, and the winner leads the next trick. Cards of other suits win
nothing. (Implemented by `winner: highestOfLedSuit`,
`nextLeader: winner`; source: Pagat — Hearts, "Play".)

## 4. Scoring

**HRT-4.1 — Penalty points.** At the end of each deal every heart a player
has taken scores 1 penalty point against them and the queen of spades
scores 13. The points a player took in the deal are added to their
match score. (Implemented by the `score` phase's per-seat effects and the
`penalty`/`bonus` rule definitions; source: Pagat — Hearts, "Scoring".)

**HRT-4.3 — Shooting the moon.** A player who takes all 26 penalty points
in a deal has shot the moon. With the `moon` option set to `addToOthers`
(the default), every other player takes 26 penalty points for the deal and
the shooter's own penalty is cancelled. With `subtractFromSelf`, the
shooter instead subtracts 26 points from their own match score. With
`shooterChooses`, the shooter is asked which of the two treatments applies
before the deal is scored. (Implemented by the `score` phase's moon branch
and its `moon` choice; source: Pagat — Hearts, "Shooting the moon".)

**HRT-4.4 — Jack of diamonds.** With the `jackOfDiamonds` option (default
off), the jack of diamonds scores −10 to the player who takes it, and may
be a reason to take a trick that would otherwise be avoided.
(Implemented by the `bonus` rule definition; source: Pagat — Hearts,
"Omnibus variants".)

## 5. Ending the match

**HRT-5.1 — Target and winner.** After each deal, if any player's match
score has reached the `target` option (default 100), the match ends and the
player with the lowest score wins. Tied low scores are shared.
(Implemented by the ruleset `end` block, rank `ascending(match.score)`,
ties `shared`; source: Pagat — Hearts, "Scoring".)

## Options summary

| Option | Type | Default | Rule |
| --- | --- | --- | --- |
| `passSchedule` | enum | `leftRightAcrossHold` | HRT-2.1 |
| `passCount` | int 1–4 | 3 | HRT-2.2 |
| `noPointsFirstTrick` | bool | on | HRT-3.3 |
| `breakingHearts` | bool | on | HRT-3.4 |
| `queenBreaksHearts` | bool | on | HRT-3.4 |
| `moon` | enum | `addToOthers` | HRT-4.3 |
| `jackOfDiamonds` | bool | off | HRT-4.4 |
| `target` | int 25–500 | 100 | HRT-5.1 |

## Defaults chosen while writing these rules

- The "hold" entry of the pass schedule deals without a pass phase; the
  pass rules above apply only to the passing deals. (Logged in
  `docs/OPEN_QUESTIONS.md` only if a play difference had been possible; the
  schedule itself is pinned by the ruleset.)
- The queen of spades breaks hearts only while `queenBreaksHearts` is on;
  with it off, only a heart breaks hearts. Both readings exist in the wild;
  the option makes the choice explicit rather than assumed.
