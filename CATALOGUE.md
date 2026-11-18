# Catalogue and Release Waves

Version 1.0 · 2026-11-15. Scope is **traditional Western card games**, including games widely played in Europe and the Americas, plus close relatives adopted there (for example Durak). This is a maintained catalogue, not a claim that every village variant is enumerated. "All major" means the initial coverage list below plus a published request process; the library may list a game before it is playable, but every entry must show separate **Read**, **Learn**, and **Play** badges, with honest status. Never advertise a catalogue count as a playable-game count.

## 1. Priority and Launch Contract

| Wave | Scope | Ship Commitment |
| --- | --- | --- |
| **1** | 10 core games: Bridge, Hearts, Euchre, Cribbage, Spades, Gin, Crazy Eights, Go Fish, Klondike, FreeCell | Initial public release: playable offline, solo bots, hand-on-phone, original rulebook, and lessons for each. Bridge may be human-only at the first internal slice; a competent basic bidding bot is required before public release. |
| **2** | 14 additional games (including Spider) and key variants | Initial GLM extension (P11), separately shippable if verified; do not delay the core ten for an unverified extra. |
| **3** | 21 regional games: continental Europe, Latin decks, tarot, hidden teams | GLM produces a **verified first tranche of five** (Briscola, Scopa, Belote, Skat, French Tarot) in P11; the rest are a staffed expansion backlog, not a promise to complete inside P11. |
| **4** | Broad regional, historical, family, and patience expansion | Catalogue-first; each game receives the game-onboarding gate before Play is enabled. |
| **C** | Optional casino/play-money pack | Human product and age-rating decision required; excluded from initial implementation by default. |

Why this order: YouGov's 2023 U.S. poll supports familiar entry games (83% had played solitaire, 79% Go Fish, 56% Crazy Eights, 52% Gin, 50% Spades). Bridge and Cribbage are deliberately prioritized despite lower reach because they directly test the accessibility and private-hand brief. Euchre validates variant-heavy trick play. Waves 2–3 stress duplicate decks, melds, hidden teams, non-French decks, and tarot without attempting every national system at once. Popularity data is American and dated, not a world market estimate (source S63 in `RESEARCH.md`).

## 2. Master Catalogue

Player counts identify intended family coverage; the first named profile may support fewer counts (for example four-player French Tarot before three/five). The base deck shown is a logical deck, not a copyrighted artwork pack. Most sources are direct Pagat pages; family-index sources explicitly require exact profile-source selection before implementation. Official-body sources and secondary references appear in §3.

| Game | Family | Deck | Players | Wave | Rule Source | Profile Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Contract Bridge | Plain Trick / Auction | French 52 | 4 | 1 | [Pagat](https://www.pagat.com/auctionwhist/bridge.html) | Rubber first; Chicago, duplicate board scoring next. Auction and play, dummy, claims; full tournament administration excluded. |
| Hearts | Penalty Trick | French 52 | 4 | 1 | [Pagat](https://www.pagat.com/reverse/hearts.html) | Black Lady base; moon scoring, pass schedule, jack of diamonds. |
| Euchre | Plain Trick / Trump | Euchre 24 | 4 | 1 | [Pagat](https://www.pagat.com/euchre/euchre.html) | Stick the dealer, lone hands; Benny and Canadian loner later. |
| Cribbage | Adding / Combination | French 52 | 2 | 1 | [Pagat](https://www.pagat.com/adders/crib6.html) | Six-card to 121; automatic counting base, manual counting and muggins later. |
| Spades | Exact-Bid Trick | French 52 | 4 | 1 | [Pagat](https://www.pagat.com/auctionwhist/spades.html) | Partnership; nil, bags, target. Joker Spades in Wave 2. |
| Gin Rummy | Draw / Discard Rummy | French 52 | 2 | 1 | [Pagat](https://www.pagat.com/rummy/ginrummy.html) | Knock, gin, undercut; Oklahoma gin later. |
| Crazy Eights | Matching / Shedding | French 52 | 2–6 | 1 | [Pagat](https://www.pagat.com/eights/crazy8s.html) | Basic matching; draw one/until playable option; no proprietary UNO assets. |
| Go Fish | Asking / Collection | French 52 | 2–6 | 1 | [Pagat](https://www.pagat.com/quartet/gofish.html) | Rank requests and books; no proprietary packs. |
| Klondike | Patience / Solitaire | French 52 | 1 | 1 | [Pagat](https://www.pagat.com/solitaire/card.html) | Draw one and three; limited/unlimited redeals. |
| FreeCell | Patience / Solitaire | French 52 | 1 | 1 | [Pagat](https://www.pagat.com/solitaire/card.html) | Standard eight cascades, four cells; Microsoft-compatible deals. |
| Spider | Patience / Solitaire | French 104 | 1 | 2 | [Pagat](https://www.pagat.com/solitaire/card.html) | One-, two-, and four-suit modes. |
| Whist | Plain Trick | French 52 | 4 | 2 | [Pagat](https://www.pagat.com/whist/whist.html) | Short/long scoring; bridge stepping stone. |
| Oh Hell | Exact-Bid Trick | French 52 | 3–7 | 2 | [Pagat](https://www.pagat.com/exact/ohhell.html) | Hand-size schedule; dealer hook optional. |
| Bid Whist | Auction Trick | French 52 + Jokers | 4 | 2 | [Pagat](https://www.pagat.com/auctionwhist/bidwhist.html) | Uptown/downtown, no-trump, kitty; joker treatment explicit. |
| Rummy | Draw / Discard Rummy | French 52 | 2–6 | 2 | [Pagat](https://www.pagat.com/rummy/rummy.html) | Basic 7/10-card rummy; optional layoff. |
| 500 Rummy | Draw / Discard Rummy | French 52 | 2–6 | 2 | [Pagat](https://www.pagat.com/rummy/500rum.html) | Discard-pile pickup and meld scoring. |
| Canasta | Meld-Scoring Rummy | French 104 + 4 Jokers | 4 | 2 | [Pagat](https://www.pagat.com/rummy/canasta.html) | Classic partnership; frozen pile and wild cards. Modern American separate variant. |
| Pinochle | Meld / Point Trick | Pinochle 48 | 4 | 2 | [Pagat](https://www.pagat.com/marriage/auction_pinochle.html) | Single-deck partnership auction. Distinct meld/trick ledgers. |
| Double-Deck Pinochle | Meld / Point Trick | Pinochle 80 | 4 | 2 | [Pagat](https://www.pagat.com/marriage/pindd.html) | Separate game record with shared family mechanics. |
| Sevens (Fan Tan) | Matching / Layout | French 52 | 3–8 | 2 | [Pagat](https://www.pagat.com/layout/sevens.html) | Build suits outward from sevens. |
| Golf | Exchange / Comparison | French 52 or multiple | 2–6 | 2 | [Pagat](https://www.pagat.com/draw/golf.html) | Six-card first; four-, eight-, and nine-card variants later. |
| President | Climbing / Shedding | French 52 | 3–8 | 2 | [Pagat](https://www.pagat.com/climbing/president.html) | Passing, clear piles, rank transfer options. |
| Durak | Beating / Shedding | French 36 | 2–6 | 2 | [Pagat](https://www.pagat.com/beating/podkidnoy_durak.html) | Throw-in; transfer variant separate overlay. |
| Pitch (Setback) | All Fours / Point Trick | French 52 | 2–6 | 2 | [Pagat](https://www.pagat.com/allfours/pitch.html) | Four-point base; 5-, 7-, and 10-point options later. |
| Skat | Point Trick / Bidding | Piquet or German 32 | 3 | 3 | [Pagat](https://www.pagat.com/schafkopf/skat.html) | ISkO suit, grand, null; hand games, matadors, overbidding. |
| Bavarian Schafkopf | Point Trick / Hidden Teams | German 32 | 4 | 3 | [Pagat](https://www.pagat.com/schafkopf/bavarian.html) | Sauspiel, Wenz, solo; hidden called-ace partner. |
| Sheepshead | Point Trick / Hidden Teams | French 32 | 3–5 | 3 | [Pagat](https://www.pagat.com/schafkopf/shep.html) | Five-player picker and called-ace partner first; 3/4-player later. |
| Doppelkopf | Point Trick / Hidden Teams | Doppelkopf 48 | 4 | 3 | [Pagat](https://www.pagat.com/schafkopf/doko.html) | DDV standard; announcements, wedding, solos; 40-card option. |
| Belote | Jass / Point Trick | Piquet 32 | 4 | 3 | [Pagat](https://www.pagat.com/jass/belote.html) | Classic French with/without declarations; Coinche is a separate entry. |
| Coinche / Contrée | Jass / Point Trick | Piquet 32 | 4 | 3 | [Pagat](https://www.pagat.com/jass/coinche.html) | Auction and doubling variants; distinguish them explicitly. |
| Klaverjassen | Jass / Point Trick | Piquet 32 | 4 | 3 | [Pagat](https://www.pagat.com/jass/klaverjassen.html) | Amsterdam/Rotterdam trump obligations and roem. |
| Schieber Jass | Jass / Point Trick | Swiss or French 36 | 4 | 3 | [Pagat](https://www.pagat.com/jass/schieber.html) | Trump, obenabe, undenufe; push; declarations optional. |
| Briscola | Ace-Ten / Point Trick | Italian 40 | 2–4 | 3 | [Pagat](https://www.pagat.com/aceten/briscola.html) | Two-player base; partnership, called-briscola later. |
| Brisca | Ace-Ten / Point Trick | Spanish 40 | 2–4 | 3 | [Pagat](https://www.pagat.com/aceten/brisca.html) | National deck and variant treatment, not a reskinned Briscola label. |
| Scopa | Fishing / Capture | Italian 40 | 2–4 | 3 | [Pagat](https://www.pagat.com/fishing/scopa.html) | Primiera, settebello, sweeps; scopa d’assi separate option. |
| Escoba | Fishing / Capture | Spanish 40 | 2–4 | 3 | [Pagat](https://www.pagat.com/fishing/escoba.html) | Captures total 15; sweeps. |
| Cassino (Casino) | Fishing / Capture | French 52 | 2–4 | 3 | [Pagat](https://www.pagat.com/fishing/casino.html) | Builds, big/little casino, sweeps; spelling aliases indexed. |
| Tute | Marriage / Point Trick | Spanish 40 | 4 | 3 | [Pagat](https://www.pagat.com/marriage/tute.html) | Partnership, declarations, forced trump/head rules. |
| Mus | Vying / Partnership | Spanish 40 | 4 | 3 | [Pagat](https://www.pagat.com/vying/mus.html) | Grande, chica, pares, juego; envites, órdago; no covert camera signaling. |
| Piquet | Declaration / Plain Trick | Piquet 32 | 2 | 3 | [Pagat](https://www.pagat.com/notrump/piquet.html) | Carte blanche, point, sequences, sets, repique, pique, capot. |
| Bezique | Marriage / Meld Trick | Bezique 64 | 2 | 3 | [Pagat](https://www.pagat.com/marriage/bezique.html) | Meld reuse constraints; variations by number of decks later. |
| French Tarot | Tarot / Point Trick | Tarot 78 | 3–5 | 3 | [Pagat](https://www.pagat.com/tarot/frtarot.html) | Four-player first; FFT contracts, bouts, Excuse, petit au bout, handfuls. |
| Königrufen | Tarock / Point Trick | Tarock 54 | 4 | 3 | [Pagat](https://www.pagat.com/tarot/koenig.html) | Called king and multiple contracts; separate national rule profile. |
| Schnapsen | Marriage / Point Trick | French/German 20 | 2 | 3 | [Pagat](https://www.pagat.com/marriage/schnaps.html) | Draw phase, closed stock, marriages, closing obligations. |
| Sixty-Six | Marriage / Point Trick | French/German 24 | 2 | 3 | [Pagat](https://www.pagat.com/marriage/66.html) | Keep distinct from Schnapsen; rules of closing and last trick. |
| Dreiertarock | Tarot / Point Trick | Tarock 54 | 3 | 4 | [Pagat](https://www.pagat.com/tarot/) | Country-specific Austrian profile; dedicated source to be selected. |
| Tressette | Point Trick | Italian 40 | 4 | 4 | [Pagat](https://www.pagat.com/tressette/tressette.html) | Partnership; card-value fractions stored in thirds. |
| Manille | Point Trick | French 32 | 4 | 4 | [Pagat](https://www.pagat.com/manille/) | Ten high; regional variants. |
| Klabberjass | Point Trick | French 32 | 4 | 4 | [Pagat](https://www.pagat.com/jass/klabberjass.html) | Two-player declaration and trump-order variants. |
| Écarté | Plain Trick / Exchange | Piquet 32 | 2 | 4 | [Pagat](https://www.pagat.com/trumps/ecarte.html) | Proposal exchange and five tricks. |
| Napoleon (Nap) | Auction Trick | French 52 | 3–6 | 4 | [Pagat](https://www.pagat.com/trumps/nap.html) | Five-card trick auction, misère variants. |
| Five Hundred | Auction Trick | French 43 incl. Joker | 4 | 4 | [Pagat](https://www.pagat.com/euchre/500.html) | Australian profile first; US double-nullo separate. |
| Bid Euchre | Auction Trick | French 24/32/48 | 4–6 | 4 | [Pagat](https://www.pagat.com/euchre/bideuch.html) | Family of profiles; do not assume one universal deck. |
| Pedro / Cinch | All Fours / Point Trick | French 52 | 4–6 | 4 | [Pagat](https://www.pagat.com/allfours/pedro.html) | Partner point capture, high/low pedro. |
| Preferans | Preference / Auction Trick | Piquet 32 | 3 | 4 | [Pagat](https://www.pagat.com/preference/) | Russian profile; scoring ledger and whisting. |
| Ninety-Nine (Trick Game) | Exact-Bid Trick | French 36 | 3 | 4 | [Pagat](https://www.pagat.com/exact/99.html) | Discarded cards encode bid; not the adding game. |
| Ninety-Nine (Adding Game) | Adding | French 52 | 2–6 | 4 | [Pagat](https://www.pagat.com/adders/98.html#99) | Cards adjust the running total; distinguish from trick game. |
| Thirty-One (Scat) | Exchange / Comparison | French 52 | 2–7 | 4 | [Pagat](https://www.pagat.com/draw/scat.html) | Draw, exchange, knock; not banking Thirty-One. |
| Hand and Foot | Meld-Scoring Rummy | Multiple French + Jokers | 2–6 | 4 | [Pagat](https://www.pagat.com/rummy/handfoot.html) | Highly variable; select named profile and expose frozen-pile rules. |
| Contract Rummy | Meld-Scoring Rummy | Multiple French + Jokers | 2–6 | 4 | [Pagat](https://www.pagat.com/rummy/ctrummy.html) | Per-deal required melds, buying discards. |
| Kalooki / Kalookie | Meld-Scoring Rummy | Multiple French + Jokers | 2–6 | 4 | [Pagat](https://www.pagat.com/rummy/kaluki1.html) | Explicit national profile; wild cards. |
| Chinchón | Meld-Scoring Rummy | Multiple French + Jokers | 2–6 | 4 | [Pagat](https://www.pagat.com/rummy/) | Spanish 40/48; regional scoring and going-out rules. |
| Old Maid | Passing / Shedding | French 51 | 2–8 | 4 | [Pagat](https://www.pagat.com/passing/oldmaid.html) | Rank pairs, unpaired queen; anonymous card backs prevent leaks. |
| War | War / Accumulation | French 52 | 2 | 4 | [Pagat](https://www.pagat.com/war/war.html) | Finite action cap, cycle detection; little decision depth. |
| Concentration | Memory / Layout | French 52 | 1–4 | 4 | [Pagat](https://www.pagat.com/misc/) | Source selection required; memory challenge disabled in comfort teaching. |
| Snap | War / Slapping | French 52 | 2–8 | 4 | [Pagat](https://www.pagat.com/war/snap.html) | Optional turn-based accessible mode labeled a variant. |
| Egyptian Ratscrew | War / Slapping | French 52 | 2–8 | 4 | [Pagat](https://www.pagat.com/war/egyptrat.html) | Timing conflict resolution needs dedicated mechanic; not GLM scope. |
| Beggar My Neighbor | War / Slapping | French 52 | 2–8 | 4 | [Pagat](https://www.pagat.com/war/beggar_my_neighbour.html) | Cycle detection and cap. |
| Russian Bank | Competitive Patience | French 104 | 2 | 4 | [Pagat](https://www.pagat.com/patience/crapette.html) | Compulsory plays and stop calls. |
| Spite and Malice | Competitive Patience | French 104 | 2 | 4 | [Pagat](https://www.pagat.com/patience/spitemal.html) | Stock piles, wild kings; not proprietary Skip-Bo. |
| Spit / Speed | Real-Time Patience | French 52 | 2 | 4 | [Pagat](https://www.pagat.com/patience/spit.html) | Distinct rulesets; timing mechanic deferred for accessibility review. |
| Cheat (I Doubt It) | Beating / Bluffing | French 52 | 3–8 | 4 | [Pagat](https://www.pagat.com/beating/cheat.html) | Challenges and bluff statements. |
| Newmarket | Stops / Layout | French 52 | 3–8 | 4 | [Pagat](https://www.pagat.com/stops/) | Play-money stakes only; dedicated exact source required. |
| Michigan / Tripoli | Stops / Layout | French 52 | 3–8 | 4 | [Pagat](https://www.pagat.com/stops/3in1.html) | Three-part session; original assets, no branded board reproduction. |
| Pyramid | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Golf (Patience) | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Canfield | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Yukon | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Forty Thieves | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Accordion | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Baker’s Dozen | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Gaps / Montana | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| La Belle Lucie | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Aces Up | Patience / Solitaire | French 52 (104 for Forty Thieves) | 1 | 4 | [Pagat](https://www.pagat.com/solitaire/card.html) | Exact original profile and secondary source to be selected before implementation. |
| Blackjack | Banking / Gambling | French 52 | 1–7 | C | [Pagat](https://www.pagat.com/banking/blackjack.html) | Play-money only; dealer soft 17, split, double options. |
| Baccarat | Banking / Gambling | French 52 | 1–7 | C | [Pagat](https://www.pagat.com/banking/baccarat.html) | Drawing table; no real-money mechanics. |
| Texas Hold’em | Vying / Poker | French 52 | 2–10 | C | [Pagat](https://www.pagat.com/poker/variants/texasholdem.html) | Play-money only; side pots, all-ins, ties. |
| Omaha | Vying / Poker | French 52 | 2–10 | C | [Pagat](https://www.pagat.com/poker/variants/omaha.html) | Exactly two hole cards and three board cards; high/low later. |
| Five-Card Draw | Vying / Poker | French 52 | 2–10 | C | [Pagat](https://www.pagat.com/poker/variants/5draw.html) | Play-money, table stakes. |
| Seven-Card Stud | Vying / Poker | French 52 | 2–10 | C | [Pagat](https://www.pagat.com/poker/variants/7stud.html) | Exposed cards and bring-in. |
| Three-Card Brag | Vying | French 52 | 2–8 | C | [Pagat](https://www.pagat.com/vying/brag.html) | Play-money only; blind/seen stakes. |
| Sette e Mezzo | Banking | Italian 40 | 2–8 | C | [Pagat](https://www.pagat.com/banking/sette_e_mezzo.html) | Play-money only; half-point arithmetic stored in halves. |
| Bourré | Point Trick / Stakes | French 52 | 3–7 | C | [Pagat](https://www.pagat.com/rams/boure.html) | Play-money only; fold, draw, forced heading. |
| Truco | Trick / Bluff | Spanish 40 | 2–6 | 4 | [Pagat](https://www.pagat.com/put/truco_ar.html) | Argentine profile first; Uruguayan and Brazilian separate profiles; optional declared signals. |

## 3. Official and Secondary Sources

| Family | Authority or Reference | Use |
| --- | --- | --- |
| Bridge | [WBF 2017 Laws, with 2024 revisions](https://www.worldbridge.org/regulations/2017-laws-of-duplicate-bridge/), [ACBL Rubber Laws 2014](https://cdn.acbl.org/wp-content/uploads/2015/02/Laws-of-Rubber-Bridge.pdf) | Auction, play, and scoring conformance; bidding conventions are separate from laws. |
| Cribbage | [ACC 2025 Rules](https://cribbage.org/NewSite/rules/rulebook_2025.pdf) | Counting, pegging, crib flush, order of show, immediate victory. |
| Euchre | [World Euchre Federation Rules](https://www.worldeuchrefederation.com/official-rules-of-euchre) | Named North American profile, not a universal mandate over house play. |
| Skat | [ISkO, DSkV](https://skatgericht.dskv.de/internationale-skatordnung/) | Suit/grand/null, matadors, overbidding, Schneider, Schwarz. |
| Doppelkopf | [DDV Rules](https://doko-verband.de/regeln/) | Named tournament profile; verify edition at implementation. |
| French Tarot | [FFT Official Rules](https://www.fftarot.fr/assets/documents/Reglement%20FFT.pdf) | Contracts, points, bouts, Excuse, bonuses. |
| Belote | [FFB Rules](https://www.ffbelote.org/reglements-de-la-belote-avec-ou-sans-annonce/) | With/without declarations; name the exact profile. |
| Broad Secondary | [According to Hoyle, Richard L. Frey](https://www.penguinrandomhouse.com/books/56441/according-to-hoyle-by-richard-l-frey/), [Parlett's Penguin Book](https://obnb.uk/p14626417-the-penguin-book-of-card-games) | Cross-check facts; licensed books are not app-content licences. "Hoyle" is not a governing body. |
| Patience | [Solitaire Laboratory](https://www.solitairelaboratory.com/), [Pagat Solitaire Index](https://www.pagat.com/solitaire/card.html) | Detailed patience profiles and solvability context. |

## 4. Onboarding a Game (Mandatory Before Play Badge)

1. Create a source dossier: exact profile, deck, player count, primary and independent secondary sources, edition date, disputed rules, and chosen defaults.
2. Write `docs/rules/RULES-<id>.md`: numbered, original rules and scoring tables. Mark every deviation from a federation profile.
3. Encode the ruleset, declare options and rule IDs, write ≥ 20 golden replays and one scenario per rule ID; cover all scoring outcomes.
4. Run 500 random-legal simulations, 500 bot games, 2,000 redaction checks, and conformance tests (100% rule IDs). A passing generic bot is required unless explicitly labeled human-only in an internal build.
5. Write original rulebook, glossary, three lessons, and one interactive scoring example. Source URLs remain visible offline; following them requires connectivity.
6. Obtain Grok rule review and a human expert's approval for federation games (bridge, ACC cribbage, Skat, Tarot, Doppelkopf); record evidence. Enable Play only after approval.

## 5. Catalogue Metadata

Each entry stores `id`, aliases (including regional spellings), localized name, mechanism tags, objective tags, region tags (many-to-many), player counts, typical duration range (editorial estimate, not a timer), difficulty (rules complexity and strategic depth separately), deck IDs, implemented profiles, feature capability badges (Read/Learn/Play/AI/Local/Online), accessibility capabilities, source IDs, and verification status. Filters compose; search includes aliases (Cassino/Casino, Scat/Thirty-One, Setback/Pitch). Never classify only by nationality: families cross borders.

## 6. Deliberate Exclusions

Proprietary card games and branded decks (UNO, Phase 10, Skip-Bo, Rook, commercial collectible games), real-money wagering, Mahjong, dominoes, trading-card construction, collectible economies, modern licensed designer games, and non-Western families except future catalogue links. Big Two, Dou Dizhu, Hanafuda, Ganjifa, and similar families are future scope decisions, not silently promised Western coverage. Reaction games (Snap, Speed, Egyptian Ratscrew) remain later-wave because dexterity is fundamental to their standard form; accessible turn-based modes must be labeled variants.
