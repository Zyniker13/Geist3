# G3 Review — Grok (rules correctness)

**Verdict: REVIEW: GROK — PASS, with required fixes. P4.0 must close G-R1 through G-R5 before the four games are treated as rules-signed.**

Reviewed at `178718d` on `phase/P3-first-four-games`. The rulesets, rules documents, scoring natives, and trick winner are unchanged from the tree `docs/reviews/G3-REQUEST.md` describes (`7994ece` and earlier; later commits are CI, measurement, and the Claude sign-off). I did not re-run `make gate`. Automated evidence is the G3 entry in `docs/STATUS.md` and CI run 45654745210.

Scope, per the request: the four games against their cited sources, whether the defaults are sensible, and the variants the request names (Chicago, duplicate, Canadian loner, five-card cribbage). Sources are linked at the end. No source prose is copied into the rulesets.

The pass means the review is complete and P4.0 may start. It does not mean the current rules play correctly. Euchre awards tricks to the wrong card, cribbage pegging pays combinations the count did not make, and rubber honors pay a partnership bonus the laws give to one hand.

## Required

### G-R1. Euchre trumps do not win the trick

`euchre.standard` sets `winner` to `highestTrumpElseLedSuit` and also supplies a `strength` def (`Resources/Rulesets/euchre.standard.ruleset.json`, the play phase and the `strength` def). In `TrickPlayMechanic+Support.winnerOf`, a present `strength` expression short-circuits the trump partition: the card with the greatest strength wins outright, including over trump. The engine test `strengthExpressionReordersTrick` documents that shortcut as pet-card behavior.

Euchre's strength is `100` for the right bower, `99` for the left bower, and otherwise `rankIndex` of the printed rank. That index is 0-based in the euchre order `9, 10, J, Q, K, A`, so a nine is 0 and an ace is 5. Consequences in ordinary play:

- A trump nine loses to an off-suit ten, jack, queen, king, or ace.
- A trump ace ties an off-suit ace. The comparison keeps the earlier card, so an off-suit ace led before the trump ace wins the trick.
- With no trump played, an off-suit ace beats a led nine. EUC-3.3 says the highest card of the suit led wins when nobody plays trump.

The two bowers still win, because 99 and 100 outrank every natural rank. `ConformanceEuchre` EUC-3.3 only checks that case (the left bower over the ace of trump), so the suite stays green.

EUC-3.1 through EUC-3.3, and Pagat's North American section, require every trump to beat every non-trump, and the led suit to win when no trump is played. Bowers rank above the trump ace, and the left bower follows as trump; those parts are already right and should stay.

Fix: for `highestTrumpElseLedSuit`, use `strength` only to order cards inside the trump set and, when no trump was played, inside the led suit. Give the pet-card shortcut its own winner mode so the existing engine test still has a home. Add two euchre plays: a trump nine over an off-suit ace, and a led nine over an off-suit ace with no trump in the trick.

### G-R2. Cribbage pegging pays pairs and runs the count did not make

`cribbage.pegPoints` (`Packages/RulesetKit/Sources/StandardNatives+Cribbage.swift`) scores the card just played.

Pairs: it counts every card of the last rank anywhere in the current count, not the unbroken trail of that rank. Three of a kind and four of a kind are therefore paid through an intervening rank. `5-7-5` scores 2; the American Cribbage Congress 2025 rulebook scores pairs, triples, and quadruples as combinations of consecutive cards, so that play scores 0. `5-5-6-5` scores 6 (a pair royal); the last two fives are a pair and the first five is not consecutive with them, so the score is 2.

Runs: a suffix whose distinct ranks are consecutive scores `distinct count × multiplicity`. That is show scoring. The same rulebook defines a multiple straight as a show and crib feature only ("only in counting hands and crib"). During play a run is one point per card in the longest suffix of three or more cards with all different, consecutive ranks. `4-4-5-6` scores 6 in the native and in `pegPointsFixedCases`; the play score is 3 (the last three cards are 4-5-6). `6-5-4-4` scores a doubled run plus the pair; the play score is the pair only.

The show scorer is a different function and is right: combinatorial fifteens, pair multiplicity, double and triple runs, crib flush only at five, nobs in the pile being counted. The 29-hand anchor is the right shape. Do not "fix" the show scorer to match the pegging prose.

Fix `pegPoints`, replace the `4-4-5-6 → 6` expectation with 3, and add `5-7-5 → 0` and `6-5-4-4 → 2`. CRB-4.3's long-form sentence ("counting duplicate cards once each") does not match either the code or the ACC play rule; rewrite it to the play rule above.

### G-R3. Rubber honors are scored for the partnership, not for one hand

BRG-5.6 and the ruleset sentence say a player holding four or five trump honors, or four aces at notrump, scores the bonus. Pagat's rubber section says the same thing: five trump honors in one hand score 150, four in one hand score 100, four aces in one hand at notrump score 150. The ten is a trump honor. Honors are scored whether or not the contract is made.

`bridge.honors` concatenates the two hands of the partnership and counts the combined cards (`StandardNatives+Bridge.swift`, `honorsBonus` and the team filter in `bridgeHonors`). A 3–2 split scores 150 instead of 0. Four honors in one hand and the fifth in partner's hand score 150 instead of 100. The same merge awards 150 for four aces split 2–2.

The conformance honors deals put all five honors in one seat, so they do not catch the split. The rest of the rubber chain I checked against Pagat and the current undertrick table is sound, and should not be reopened to fix this:

- Trick values: minors 20, majors 30, notrump 40 then 30. Doubled ×2 and redoubled ×4, below the line only. Overtricks stay above the line.
- Undoubled undertricks 50 or 100. Doubled, not vulnerable, cumulative 100, 300, 500, 800; vulnerable 200, 500, 800, 1100. Redoubled doubles that. This is the current table (Pagat's "2nd and 3rd, then subsequent"), not the pre-1987 "200 each after the first."
- Slams 500/750 and 1000/1500, insult 50/100.
- Vulnerability is `match.games >= 1`, read before this deal increments games.
- A game at 100 below moves both columns above the line and clears them. That is the rubber line, and it keeps the opponents' partscore in the total while wiping it toward the next game.
- Rubber bonus 700 if the opponents have no game, else 500. The match ranks `match.above` after that transfer, which is the full total once the rubber-winning game has cleared below.
- Honors are applied on defeated contracts as well as made ones. Dummy is revealed after the opening lead, and declarer is the first player of the winning side to name the strain.

Fix: score each of the four hands on its own and give the side the best single-hand result. Name the ten in `docs/rules/RULES-contract-bridge.md` §5; the prose lists ace, king, queen, and jack and then says "all five."

### G-R4. The starter cut can turn the bottom card

ACC rule 3.1.c: a starter cut takes at least four cards off the top and leaves at least four on the bottom. `RevealStarterMechanic` draws `depth = floor + rng.below(count - floor)` and turns `cards[depth]`. With the floor at 4, depth runs from 4 through `count - 1`, so the lower packet can be a single card. The comment in that function says the lower packet keeps one card. After a six-card deal the stock has 40 cards, and a legal cut leaves 4 through 36 cards below.

An engine-chosen cut is a fair stand-in for the pone's cut, provided the range is the legal range. Fix the range. CRB-3.1's long text only claims the floor stops a cut of nothing or one card; extend it to both packets.

### G-R5. Chicago does not play the Chicago its rule sentence describes

BRG-C.1 says a chukker is four deals, partscores carry, and a partscore bonus is scored on the fourth deal. Pagat's standard Chicago (Four-Deal Bridge) is that game: partscores carry below the line, a game scores the 300/500 bonus, and a partscore still below the line on hand 4 scores 100. There is no 50-point bonus on earlier partscores.

The variant's score effects call `bridge.score` in `chicago` mode and add `r.total` to `above`. That mode pays 50 for every partscore and 300/500 for a game, immediately, with nothing carried. That is Pagat's separate "Chicago with Duplicate Scoring."

The vulnerability table `none, NS, EW, both` is the modern Pagat chart (hand 2 North-South, hand 3 East-West, hand 4 both), and it is the right chart. It matches the deal only when North deals hand 1 and the deal then passes East, South, West. The variant never sets `firstDealer`, so it inherits rubber's `highCut`. Whenever seat 0 does not deal the first hand, hands 2 and 3 are vulnerable on the wrong side. The overlay comment that calls hand 2 "dealer side" is the older chart; the numbers in the table are the modern one. Keep the numbers, and pin the first dealer to the North seat.

Passed-out Chicago hands already redeal with the same dealer and do not increment `dealsPlayed`. That part matches Pagat.

Fix by choosing one game and making the sentence, the dealer, and the score effects agree. Either carry partscores and pay 100 only for a partscore left below the line on deal 4, or rewrite BRG-C.1 as duplicate-scored Chicago (50/300/500, no carry) and drop the carry claim.

## Recommended

1. **Hearts defaults are a coherent American package, and they are not Pagat's base text.** Passing left, right, across, hold, three cards, the two of clubs led, follow-suit, hearts broken only by a heart unless the option says otherwise, moon detection on 26 penalty points with the jack of diamonds kept separate, and play to 100 lowest-score are right. Pagat's primary section still allows penalty cards on the first trick, does not let the queen break hearts, and scores the moon as −26 or the shooter's choice. `noPointsFirstTrick`, `queenBreaksHearts`, and `moon: addToOthers` are the usual computer-game settings, the options work, and the long rules disclose the queen choice. Record an ADR that `hearts.standard` is that package, so a later pass does not flip the defaults back to Pagat's base without a decision. A hand of only the queen and hearts must lead the queen until hearts are broken; that matches Pagat's base and the code.

2. **Euchre's other rules match the North American section of the cited Pagat page.** Twenty-four cards, no joker, bowers, maker-only alone, partner sitting out, lead skipping that partner, dealer taking the upcard unless the dealer is the one sitting out, stick-the-dealer off (Pagat lists it as a variation), lone march 4, euchre 2 to the defenders, three or four tricks 1, five tricks 2, play to 10, next dealer after two rounds of passes. Canadian loner matches Pagat: the dealer's partner may order the turned suit only alone. `firstJack` deals to the first jack of either color; Pagat mentions a black jack as a common method. Either is a fair cut. The defaults paragraph of `docs/rules/RULES-euchre.md` describes a `passOut` option the ruleset does not have. Delete that sentence. The behavior (next dealer) is already right.

3. **Bridge claims are the social shortcut the ruleset text describes, and they are not the WBF procedure the long rules cite.** Declarer states a count; a defender accepts, or rejects and play continues with the claim ignored. Laws 68–70 adjudicate a contested claim. Keep the shortcut, cite it as a house procedure, and leave Law 70 for later if you want it.

4. **Duplicate is a labeled simplification, with two edges the rule sentence should admit.** Honors are correctly absent. Per-deal 300/500 and 50 are the duplicate bonuses. An eight-board session repeats the four-board vulnerability pattern, so boards 5–8 are not the standard board chart (board 5 is North-South vulnerable, board 8 is neither). A passed-out board is redealt rather than scored 0; the overlay note already says so, and BRG-D.1 does not. State both in the rule sentence, or score a pass-out as 0 and use the eight-board chart. The same North-deals-first pin as G-R5 applies if the table is meant to follow boards 1–4.

5. **The five-card overlay is a house rule, and it is not the Pagat game it cites.** Its own sentence (five cards, lay away one, crib of two, play to 61) matches the patch. Pagat's five-card cribbage, now at `https://www.pagat.com/adders/cribbage.html` (the cited `crib5.html` URL returns 404), discards two, plays a single sequence up to 31, and gives the non-dealer 3 for last on the first deal, to 61. The G3 request's "11-point game" matches neither. Point the source at the house rule, or implement the Pagat game. Six-card cribbage is unaffected.

6. **Muggins and manual counting fault if turned on.** Default off matches ACC, where muggins is the tournament director's option. Keep those toggles out of the shipping UI until the show mechanic can apply them. A fault is better than a silent wrong count.

7. **Claude's R1 is also a rules defect.** Card IDs assigned in deal order let any later viewer recover who was dealt a card once that card is played or, in cribbage, once the crib is shown. That breaks HRT-2.2 (only the recipient learns the passed cards) and CRB-2.1 (the crib stays hidden, and neither player learns the other's lay-away). I agree it is required. It is not given a second number here.

## Checked and sound

**Hearts.** Thirteen each, blind pass, schedule left / right / across / hold via `passOffset` `[1, 3, 2, 0]`, two of clubs led, follow-suit, no penalty card on the first trick unless the hand is all penalty cards, hearts led only after a heart (or the queen, when the option is on) unless the hand is all hearts, highest of the led suit wins, 1 per heart and 13 for the queen, moon on `penaltyTaken == 26` with the jack's −10 left on its taker, `addToOthers` gives the others 26 and the shooter only the jack bonus, `subtractFromSelf` gives the shooter −26 plus that bonus, game at 100, lowest score wins, ties shared. Jack of diamonds defaults off.

**Euchre, aside from G-R1.** The score ladder, the alone forms, stick-the-dealer only on the second-round pass, the turned-down suit forbidden in round two, and the left bower counted as trump for following are right. The deal is 3 then 2 and one upcard, which is a fair 24-card deal.

**Cribbage show, heels, go, and the race to 121.** Fifteens, pairs, runs, flush, and nobs in `cribbage.handScore` match ACC, including a four-card flush only in the hand and a five-card flush in the hand or the crib. The ruleset sentence for CRB-5.2 says this. The long rules and `docs/HANDOFF.md` §6 say the five-card flush exists only in the crib; that sentence is false, and G-R2's prose fix should correct it. "Nibs" in the long doc is ACC's other name for his heels; the one-point jack is nobs, and it scores in the crib as well as the hand. His heels are 2 for a jack starter. Pegging order starts with the pone. A go scores 1 to the last player, 31 scores 2 and does not also score the 1, and the opponent of that player leads the next sequence. In two-player play that is the player who called go, which is ACC 1.5.e(2) and 7.1.b. The show counts pone, dealer, then crib, and the continuous end check stops the deal between those steps, so a peg-out ends the game before the remaining piles. Skunk at a score below 91 (121-point game) or 46 (61-point game) matches the 2025 book: a win by 31 or more, stink hole 90. The extracted 2025 text records a skunk as three game-points and does not define a further double skunk; emitting `skunk` is the right signal for one game. Low-card cut for first deal breaks ties by recutting, ace low.

**Bridge rubber, aside from G-R3.** Listed under G-R3 so the scoring fix does not disturb it. Opening leader is the seat to declarer's left. Claims, as a house shortcut, are recommendation 3.

## Sources

- Hearts: https://www.pagat.com/reverse/hearts.html (primary section and the variations for the queen, the first trick, and the moon).
- Euchre: https://www.pagat.com/euchre/euchre.html (North American section for the 24-card game; British section is a different game and was not used as the standard).
- Rubber, Chicago, duplicate bonuses, honors, undertricks: https://www.pagat.com/auctionwhist/bridge.html
- Cribbage play and the show: https://www.cribbage.org/NewSite/rules/rulebook_2025.pdf (2025 ACC rulebook: rules 1.5–1.7, 3.1, 6.3, 7.1, 7.2, and the glossary entries for flush, nobs, his heels, straight, and skunk).
- Five-card cribbage: https://www.pagat.com/adders/cribbage.html

Reviewed-by: GROK, 2026-11-25, PASS
