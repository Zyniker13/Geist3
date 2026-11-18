# Research Findings and Source Register

Research date: November 15, 2026 (Eastern Time). Sources below were consulted through web-search results, public pages, documentation, or repository metadata during this research pass. A search-result excerpt is not equivalent to a full manual audit: **Read** identifies an opened public page; **Search** identifies a source surfaced with relevant extracts; **Metadata** identifies repository licence metadata checked directly. Prices and review samples are snapshots, not promises of future availability. Reference IDs are stable within this package. Game-specific Pagat links are additionally recorded in `CATALOGUE.md`.

## 1. Executive Findings

1. **The private-hand concept is established, not unoccupied territory.** The Card Table already describes an iPad/Mac table and iPhone/iPad hands over direct local connections. Stillwind's Table advertises the same iPad-table/phone-hand pattern, and Play Table uses a TV table with phone hands. Differentiate through rules enforcement, a serious catalogue, teaching, senior-friendly accessibility, offline local play, and trustworthy variants—not a claim to have invented a phone hand. [S42–S47]
2. **A physics sandbox is not a rules engine.** GreenCloth and The Card Table deliberately leave rules and scoring to players. That is flexible but pushes shuffling, rule adjudication, scoring, and motor complexity back onto the user. Our default is enforced rules and large tap controls, with an eventual unrefereed table considered separately. [S42, S45]
3. **There is no single correct Hearts, Euchre, or Canasta.** Pagat explicitly prioritizes authentic practice and documents house variation. Model the named profile, source edition, defaults, and deviations. “Official” means a particular body/profile, not ownership of a traditional game. [S01–S06, S12]
4. **One universal rules language is a research project.** GDL-II models percepts, Ludii composes ludemes, CardStock/RECYCLE models card cycles, and OpenSpiel separates game states, observations, and chance nodes. Each supplies ideas, not a native accessible iOS product ready to embed. The practical choice is a hybrid: compiled mechanics, declarative JSON composition, and a bounded expression language. [S17–S29]
5. **Do not start new work on Multipeer Connectivity.** Apple's TN3213 says Xcode 27 deprecates the framework and explains migration to Network, which supports peer-to-peer Wi-Fi without Multipeer. It also warns TLS-PSK has limitations (no QUIC, no TLS 1.3, older API only). Choose Network with authenticated TLS and a client-server topology. [S31–S36]
6. **Accessibility shapes the rendering architecture.** SwiftUI semantic controls are preferable to a SpriteKit canvas for a game whose objects are cards, buttons, bids, and score sheets. VoiceOver, Switch Control, keyboard navigation, target spacing, and no-drag interaction are core acceptance requirements, not P15 polish. [S50–S58]
7. **Bridge AI is a separate substantial product.** DDS solves perfect-information card play, not bidding or hidden-information bridge. GIB combines sampling and double-dummy solving; Ben uses learned bidding but its GPL licence is not a safe drop-in for the default closed-source Apple release. Build basic explainable bidding first, with an isolated DDS adapter and PIMC cardplay. Never promise expert human-quality bidding in the first slice. [S19, S65–S72]
8. **A 94-entry catalogue is plausible; 94 polished playable games at launch is not.** Ten launch games stress several key engine shapes. Wave 2 adds fourteen, and five regional proof games validate Wave 3 mechanics. Each remaining game has its own rule conformance gate. [S01–S16, `CATALOGUE.md`]
9. **Teaching should reuse the real engine.** Bridge Master demonstrates constructed deals with explanations, Cuebids focuses on partnership bidding, and Cribbage Pro explains discard EV. Reusing the production engine prevents tutorials from quietly teaching different rules. [S59–S62]
10. **Price is less urgent than friction.** Review samples repeatedly raise ads, interrupted play, weak bots, confusing variants, clutter, and reconnect problems. A premium no-ad product is the default; Mahler decides the final price. Published prices vary by region and billing channel. [S38–S49, S73–S76]

## 2. Taxonomy, Rules, and Rights

Pagat's actual top-level mechanism classification is **outplay, exchange, comparison, layout, and other**, not a flat list of genres. Trick-taking, fishing, matching, adding, beating, climbing, and war sit beneath outplay. Rummy sits under draw-and-discard exchange. Patience involves layouts and a shedding objective; poker is vying/comparison; banking is distinguished from equal-player vying. The app should support mechanism and objective as independent facets, then region, deck, player count, duration, rules complexity, and strategic depth. This avoids confusing “shedding” (an objective) with “trick-taking” (a mechanism). [S01–S04]

French, German, Swiss, Spanish, Italian, and tarot card systems cannot be modeled as “52 cards plus a skin.” Logical suits, ranks, duplicated copies, trump families, and point values differ. Card faces must be independent artwork packs over logical decks. Tarot needs knights, numbered trumps, and an Excuse; pinochle and Doppelkopf need repeated face instances; Spanish/Italian games often use 40 cards and no 8–9. [S03, S14–S16]

The bridge law sources distinguish **2014 rubber laws** and **2017 duplicate laws with revised Laws 73 and 89 effective January 2024**. Do not mix rubber vulnerability/game scoring with duplicate board scoring. Bidding conventions (SAYC, Acol, 2/1) are agreements, not laws. ACC's published rulebook is the **2025 edition**, effective August 1, 2025. The DDV source register has a **2026** rules revision, so pin exact editions at implementation. [S07–S13]

U.S. Copyright Office guidance distinguishes game methods from protected expression. That is not permission to copy Pagat paragraphs or federation diagrams. Pagat's policy permits links but reserves reproduction rights. Original prose, original artwork, source links, edition tracking, and a rights ledger are required. Copyright, trademark, database rights, and local law still need release review by a qualified reviewer; this package is product research, not a legal opinion. [S05–S06, S77–S80]

## 3. Rules Engine Prior Art and Decision

| Approach | Strength | Problem for This App | Adopt |
| --- | --- | --- | --- |
| GDL/GDL-II | Formal transitions and private percepts; general reasoning | Verbose, harder to author, and no accessible product UI | Private observations and formal conformance thinking |
| Ludii/ludemes | Reusable compositional game primitives | Card-game support and high-level visibility remain evolving; Java runtime mismatch | Mechanics vocabulary and composition |
| OpenSpiel | Clean extensive-form games, chance nodes, information states, algorithms | C++/Python research library; not a rulebook/editor app | Observation separation and test oracle ideas |
| RLCard | Practical RL environments and baseline algorithms | Training infrastructure and game-specific observations are not our universal engine | Benchmark ideas; no runtime dependency |
| CardStock/RECYCLE | Explicit stages/cycles and automatic playtesting | GPL repository; older research scope | Phase composition and simulation-before-play |
| Zillions/ZRF | Declarative games and reusable macros | Board-centric, imperfect-information/card fit, proprietary runtime | Data-driven discipline, not embedding |
| boardgame.io | Server authority, `playerView`, and secret-state filtering | Web/JavaScript stack mismatch | Per-viewer projections, filtered events, hidden RNG |
| Tabletop Simulator Lua | Flexible user scripting and physical metaphor | Trusted scripts, desktop/motor burden, no semantic rules enforcement | Nothing in runtime; useful negative UX comparison |
| Full user scripts | Expressive and quick for an experienced author | Sandboxing, App Review, determinism, and explanation risks | Reject for v1 |
| **Our hybrid** | Tested Swift mechanics + bounded expressions + JSON overlays | Mechanics library still requires substantial engineering | **Fixed decision** |

CEL and Starlark show safe-expression/configuration principles, but “non-Turing-complete” alone is not a denial-of-service guarantee. Meter operations, cap inputs, disallow recursion and unbounded allocation, and roll back runtime faults. JavaScriptCore execution-time hooks surfaced in research are **private API** and must not be used. A WASM interpreter avoids JIT but does not solve App Review or authoring complexity. [S23–S30, S81–S84]

## 4. Networking and Hidden Information

- Use a **host-authoritative star** and send a separately redacted observation to each seat. “Card backs are visible on the table” is not security if their faces travel in the same payload. Exclude hidden faces, RNG state, hidden team identities, legal-move data for other seats, debug dumps, and unredacted events. [S25, S31]
- Keep private/public knowledge explicit: a passed Hearts card is known to its sender, a Euchre up-card is known even after pickup, bridge dummy becomes public only after the opening lead. Do not equate “currently face down” with “unknown.” [S01, S07, S09]
- Local networking must survive denied local-network permission, client sleep, host backgrounding, network changes, duplicate messages, stale actions, and reconnect. Peer-to-peer Wi-Fi must be tested physically; simulator success is not evidence of airplane/car operation. [S31–S35]
- DeviceDiscoveryUI on Apple TV is a convenience, **not general guest discovery**: its picker limits devices to the user's account or iCloud family. Use Bonjour and QR joining as the baseline. [S36]
- GameKit real-time can target players, but shared turn-based match data cannot safely store all hands. SharePlay establishes a group experience; it is not itself an authoritative game server. Handoff transfers an activity and does not replace live synchronization or seat authorization. [S37, S85–S88]
- Trust limits must be explicit: a local host necessarily sees all cards. Seed commitments prevent post-commitment deck substitution, not seed selection or collusion. Dealer-less “mental poker” is a cryptographic research project, deliberately excluded. [S89]
- App Clips cannot perform local-network browsing and communication in the same way as a full app; do not promise QR-to-instant-offline joining without an install. A browser companion is a separate future web stack, not a GLM shortcut. [S90]

## 5. Accessibility and Teaching Findings

NN/g reports older adults struggling with small targets, complex navigation, and dexterity demands. This is directional usability evidence, not proof that all older adults need simplified games. Preserve strategic depth while removing motor burden: stable rows or grids, large targets, an explicit Play button, infinite default thinking time, adjustable pace, and an iPad hand role. Test with older adults and players who actually use assistive technologies. [S50–S58]

Four suit colors can help some players, but colorblindness differs. Always retain distinct suit shapes, large rank indices, a high-contrast mode, spoken suit names, and optional suit letters. VoiceOver announces private cards on the private device; the app must warn that speaker audio can reveal a hand and offer headphones/private narration. A shared Table Caller narrates only public events. [S53–S58]

Teaching uses (1) a concise rulebook, (2) embedded try-it examples, (3) guided stacked deals, (4) optional nudges/hints/explanations, (5) focused trainers, and (6) post-deal review. Double-dummy analysis must be labeled **all-cards-visible analysis**, not necessarily the best practical line with hidden information. [S59–S62, S65–S72]

## 6. Market Snapshot and Pain Points

| Product | Observed Offer | Price Evidence | Lessons |
| --- | --- | --- | --- |
| The Card Table | iPad/Mac table, private iPhone/iPad hands; manual rules | US listing opened: $1.99 plus IAP; small sample (12 ratings) | Old reviews requested hand sorting, zoom, and scorekeeping; version history says those were added. Do not present 2014 complaints as current defects. |
| Stillwind Table | Shared iPad table, phone hands; four classic games plus originals | No verified price in opened page | Direct feature overlap; do not claim invention. |
| Play Table | TV/browser table, phone hands, classic and party games | Site says free joining and one-time cosmetic/add-on purchases | QR joining and persistent seats across games are useful patterns; offline claims not independently tested. |
| GreenCloth | Browser virtual pieces, private hands, custom rules by human agreement | Not verified | Rules flexibility alone does not provide teaching or enforcement. |
| Card Shark Collection | Large solo/traditional collection; themes, save, undo | Current US price not fully verified | Collection breadth is an established baseline; avoid padding game count with near-identical solitaire variants. |
| Trickster | Online trick games with configurable rules and invitations | Free listing; IAP/ads vary | Review snippets mention frozen ads/disconnects; actual current incidence unknown. |
| BBO | Online bridge, robots, clubs/tournaments, practice | Free download, paid services/ad removal | Ads, scrolling, freezing, and screen density appear in review samples; specialist ecosystem is far deeper than a v1 bridge module. |
| Funbridge | Solo bridge, rankings, analysis | Search surfaced US IAP: Premium $17.99/month, $199.99/year; verify before pricing decisions | Strong training benchmark; do not infer prices apply worldwide. |
| Shark Bridge | Offline robots, hints, teaching ecosystem | Search surfaced $29.99 enthusiast upgrade, $34.99/year VIP | Offline bridge is an important benchmark. |
| Bridge Baron | Solo bridge and practice | Search surfaced $7.90/month iPad subscription | Bidding-system flexibility and price clarity matter. |
| Solebon | Fifty solitaire games, rules, customization | Paid/ad-supported variants; price not verified | Polished solitaire is a demanding usability baseline. |
| Hoyle collection | Broad legacy desktop collection, tips and bots | Current price not verified | “Hoyle” signals tradition, but legacy reviews flag AI and compatibility; not an authority over all variants. |

These are **research hypotheses**, not a representative review study. P0 requires a reproducible competitor test sheet on real devices; do not quote selected reviews as market-wide defect rates. Premium no-ads is a proposed product strategy, not a user-approved purchase or final price. [S38–S49, S73–S76]

## 7. Source Register


### Rules and Taxonomy

| ID | Source | Use |
| --- | --- | --- |
| S01 | [Pagat: Classification of Card Games](https://www.pagat.com/class/) | Read |
| S02 | [Pagat: Shedding and Accumulation Games](https://www.pagat.com/class/shed.html) | Search |
| S03 | [Pagat: Mechanics of Card Games](https://www.pagat.com/mech.html) | Search |
| S04 | [Pagat: Combination Games](https://www.pagat.com/class/combine.html) | Search |
| S05 | [Pagat: Policy (copyright and linking)](https://www.pagat.com/policy.html) | Read |
| S06 | [Pagat: Home](https://www.pagat.com/) | Read |
| S07 | [WBF: 2017 Laws of Duplicate Bridge (2024 revisions)](https://www.worldbridge.org/regulations/2017-laws-of-duplicate-bridge/) | Search |
| S08 | [ACBL: Laws of Duplicate Bridge, North American Edition](https://web2.acbl.org/documentlibrary/play/laws-of-duplicate-bridge.pdf) | Search |
| S09 | [ACBL: Laws of Rubber Bridge (2014)](https://cdn.acbl.org/wp-content/uploads/2015/02/Laws-of-Rubber-Bridge.pdf) | Search |
| S10 | [American Cribbage Congress: Official Tournament Rules](https://www.cribbage.org/NewSite/rules/) | Search |
| S11 | [ACC: Cribbage Tournament Rules, 2025 Edition](https://cribbage.org/NewSite/rules/rulebook_2025.pdf) | Search |
| S12 | [World Euchre Federation: Official Rules](https://www.worldeuchrefederation.com/official-rules-of-euchre) | Search |
| S13 | [Deutscher Doppelkopf-Verband: Rules](https://doko-verband.de/regeln/) | Search |
| S14 | [DSkV: Internationale Skatordnung (2022)](https://dskv.de/app/uploads/sites/43/2022/11/ISkO-2022.pdf) | Search |
| S15 | [Fédération Française de Tarot: Règlement officiel](https://www.fftarot.fr/assets/documents/Reglement%20FFT.pdf) | Search |
| S16 | [Vivid Maps: Playing Card Suit Systems](https://vividmaps.com/playing-card-suit-systems/) | Search |

### Rules Engines and Game Description

| ID | Source | Use |
| --- | --- | --- |
| S17 | [Verlaine and Piette: Introducing Card Games in Ludii (2025)](https://ericpiette.com/master/2025%20-%20Introducing%20Card%20Games%20in%20Ludii.pdf) | Search |
| S18 | [Ludii Language Reference](https://ludii.games/downloads/LudiiLanguageReference.pdf) | Search |
| S19 | [OpenSpiel: Available Games](https://openspiel.readthedocs.io/en/latest/games.html) | Search |
| S20 | [OpenSpiel Repository (Apache-2.0)](https://github.com/google-deepmind/open_spiel) | Metadata |
| S21 | [RLCard: Reinforcement Learning in Card Games](https://rlcard.org/) | Search |
| S22 | [RECYCLEd CardStock Documentation](https://cardstock.readthedocs.io/en/latest/index.html) | Search |
| S23 | [CardStock Repository (GPL-3.0)](https://github.com/mgoadric/cardstock) | Metadata |
| S24 | [Thielscher: A General Game Description Language for Incomplete Information Games (GDL-II)](https://ojs.aaai.org/index.php/AAAI/article/download/7647/7508) | Search |
| S25 | [boardgame.io: Secret State](https://boardgame.io/documentation/secret-state.html) | Search |
| S26 | [Zillions of Games: ZRF Language](https://www.zillions-of-games.com/language/) | Search |
| S27 | [Tabletop Simulator API: Hands](https://api.tabletopsimulator.com/hands/) | Search |
| S28 | [Common Expression Language Overview](https://cel.dev/overview/cel-overview) | Search |
| S29 | [Starlark Specification](https://github.com/bazelbuild/starlark/blob/master/spec.md) | Search |
| S30 | [Starlark Issue 249: Safety on Untrusted Code](https://github.com/bazelbuild/starlark/issues/249) | Search |

### Apple Platforms and Multi-Device Play

| ID | Source | Use |
| --- | --- | --- |
| S31 | [Apple TN3213: Moving from Multipeer Connectivity to Network Framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework) | Read |
| S32 | [Apple: Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity) | Search |
| S33 | [Apple TN3179: Understanding Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | Search |
| S34 | [WWDC25: Use Structured Concurrency with Network Framework](https://developer.apple.com/videos/play/wwdc2025/250/) | Search |
| S35 | [Apple: NWParameters.includePeerToPeer](https://developer.apple.com/documentation/Network/NWParameters/includePeerToPeer) | Search |
| S36 | [Apple: Connecting a tvOS App to Other Devices over the Local Network (DeviceDiscoveryUI)](https://developer.apple.com/documentation/devicediscoveryui/connecting-a-tvos-app-to-other-devices-over-the-local-network) | Read |
| S37 | [Apple Tech Talk: Add SharePlay to Your Multiplayer Game with Game Center](https://developer.apple.com/videos/play/tech-talks/110338/) | Search |

### Market and Existing Apps

| ID | Source | Use |
| --- | --- | --- |
| S38 | [BBO Forums: BBO on Mobile](https://www.bridgebase.com/forums/topic/90610-bbo-sucks-on-mobile/) | Search |
| S39 | [App Store: Bridge Base Online Reviews](https://apps.apple.com/us/app/bridge-base-online-bbo/id529258853?see-all=reviews) | Search |
| S40 | [App Store: Card Shark Collection](https://apps.apple.com/us/app/card-shark-collection/id306967807) | Search |
| S41 | [Trickster Cards: Supported Rules](https://www.trickstercards.com/help/rules/) | Search |
| S42 | [App Store: The Card Table](https://apps.apple.com/us/app/the-card-table/id775537119) | Read |
| S43 | [Stillwind: Table](https://stillwind.games/table/) | Read |
| S44 | [Play Table](https://playtableapp.com/) | Read |
| S45 | [GreenCloth Games: Players](https://greencloth.games/players/) | Read |
| S46 | [Jackbox Games: Getting Started](https://support.jackboxgames.com/hc/en-us/articles/15794771245975-How-do-I-get-started-playing-Jackbox-Games) | Search |
| S47 | [PlayingCards.io: Quick Start](https://playingcards.io/docs/overview) | Search |
| S48 | [App Store: Trickster Cards Reviews](https://apps.apple.com/ca/app/trickster-cards/id982267355?platform=iphone&see-all=reviews) | Search |
| S49 | [Steam Community: Hoyle Official Card Games Collection](https://steamcommunity.com/app/397420/) | Search |

### Accessibility and Older Adults

| ID | Source | Use |
| --- | --- | --- |
| S50 | [NN/g: Usability for Older Adults](https://www.nngroup.com/articles/usability-for-senior-citizens/) | Search |
| S51 | [NN/g: Touch Targets on Touchscreens](https://www.nngroup.com/articles/touch-target-size/) | Search |
| S52 | [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Search |
| S53 | [r/ColorBlind: Four-Color Decks Discussion](https://www.reddit.com/r/ColorBlind/comments/1b7frrd/what_do_you_think_of_4color_decks_of_playing/) | Search |
| S54 | [Veroniiiica: Playing Cards and Low Vision](https://veroniiiica.com/playing-cards-and-low-vision/) | Search |
| S55 | [Game Accessibility Guidelines: Precise Timing](https://gameaccessibilityguidelines.com/do-not-make-precise-timing-essential-to-gameplay-offer-alternatives-actions-that-can-be-carried-out-while-paused-or-a-skip-mechanism/) | Search |
| S56 | [Xbox Accessibility Guideline 107](https://learn.microsoft.com/en-us/xbox/accessibility/xbox-accessibility-guidelines/107) | Search |
| S57 | [AppleVis: Accessible Solitaire](https://www.applevis.com/apps/ios/games/accessible-solitaire) | Search |
| S58 | [AppleVis Forum: Card Game Bridge](https://applevis.com/forum/ios-ipados-gaming/card-game-bridge) | Search |

### Teaching and Demand

| ID | Source | Use |
| --- | --- | --- |
| S59 | [Bridge.com: Bridge Master](https://bridge.com/en/play/games-modes/bridge-master/) | Search |
| S60 | [Cuebids](https://cuebids.com/) | Search |
| S61 | [Cribbage Pro: Hand Grade Analysis](https://www.cribbagepro.net/help/hand-grade-analysis.html) | Search |
| S62 | [ACBL: Free Learn to Play Bridge Software](https://web3.acbl.org/newmembers/free-learn-software) | Search |
| S63 | [YouGov: How Americans Feel About 30 Card Games (2023)](https://yougov.com/en-us/articles/45795-how-americans-feel-about-30-card-games) | Read |
| S64 | [Bridge Winners: About That Demographic Cliff](https://bridgewinners.com/article/view/about-that-demographic-cliff/) | Search |

### AI Opponents

| ID | Source | Use |
| --- | --- | --- |
| S65 | [DDS Double-Dummy Solver Repository (Apache-2.0)](https://github.com/dds-bridge/dds) | Metadata |
| S66 | [Haglund: Search Algorithms for a Bridge Double Dummy Solver](https://privat.bahnhof.se/wb758135/bridge/Alg-dds_x.pdf) | Search |
| S67 | [Ginsberg: GIB (JAIR 2001)](https://www.jair.org/index.php/jair/article/view/10279) | Search |
| S68 | [Ben Bridge Engine Repository (GPL-3.0)](https://github.com/lorserker/ben) | Metadata |
| S69 | [Bridge Winners: How Neural Networks Learn to Bid](https://bridgewinners.com/article/view/bridge-ai-how-neural-networks-learn-to-bid/) | Search |
| S70 | [Cowling, Powley, Whitehouse: Information Set Monte Carlo Tree Search (2012)](https://eprints.whiterose.ac.uk/id/eprint/75048/1/CowlingPowleyWhitehouse2012.pdf) | Search |
| S71 | [Long et al.: Understanding the Success of PIMC Sampling (AAAI 2010)](https://ojs.aaai.org/index.php/AAAI/article/view/7562) | Search |
| S72 | [Sturtevant and White: Feature Construction for Hearts](https://www.cs.du.edu/~sturtevant/papers/heartsfeatures.pdf) | Search |

### Pricing

| ID | Source | Use |
| --- | --- | --- |
| S73 | [App Store: Funbridge](https://apps.apple.com/us/app/fun-bridge/id408841149) | Search |
| S74 | [App Store: Shark Bridge](https://apps.apple.com/us/app/shark-bridge/id1532936026) | Search |
| S75 | [App Store: Bridge Baron](https://apps.apple.com/us/app/bridge-baron-improve-play/id1465176932) | Search |
| S76 | [App Store: Solebon Solitaire Reviews](https://apps.apple.com/us/app/solebon-solitaire-50-games/id283179414?platform=ipad&see-all=reviews) | Search |

### Rights and Review Policy

| ID | Source | Use |
| --- | --- | --- |
| S77 | [U.S. Copyright Office: Games](https://copyright.gov/register/tx-games.html) | Search |
| S78 | [U.S. Copyright Office FL-108 (archived)](https://web.archive.org/web/20160411131325/www.copyright.gov/fls/fl108.html) | Search |
| S79 | [MC Law: Copyright Registration of Games](https://mclaw.io/blog/copyright-registration-of-games) | Search |
| S80 | [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | Search |

### Sandboxing and Determinism

| ID | Source | Use |
| --- | --- | --- |
| S81 | [WebKit: JSContextRefPrivate.h (private execution limits)](https://github.com/WebKit/webkit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h) | Search |
| S82 | [wasm3 Interpreter](https://github.com/wasm3/wasm3) | Search |
| S83 | [Blackman and Vigna: Scrambled Linear Pseudorandom Number Generators](https://arxiv.org/abs/1805.01407) | Search |
| S84 | [Vigna: xoshiro/xoroshiro Generators and the PRNG Shootout](https://prng.di.unimi.it/) | Search |

### Apple Platform Constraints

| ID | Source | Use |
| --- | --- | --- |
| S85 | [Apple GameKit Guide: Turn-Based Matches](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/GameKit_Guide/ImplementingaTurn-BasedMatch/ImplementingaTurn-BasedMatch.html) | Search |
| S86 | [WWDC21: Build Custom Experiences with Group Activities](https://developer.apple.com/videos/play/wwdc2021/10187/) | Search |
| S87 | [SwiftUI: onContinueUserActivity](https://developer.apple.com/documentation/SwiftUI/View/onContinueUserActivity(_:perform:)) | Search |
| S88 | [Apple News: Higher Data Limits for Turn-Based Matches](https://developer.apple.com/news/?id=02012012a) | Search |
| S89 | [Wikipedia: Mental Poker](https://en.wikipedia.org/wiki/Mental_poker) | Search |
| S90 | [Apple: Choosing the Right Functionality for Your App Clip](https://developer.apple.com/documentation/appclip/choosing-the-right-functionality-for-your-app-clip) | Search |
| S91 | [App Store Connect: Age Ratings Values and Definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/) | Search |
| S92 | [Rosetta Code: Deal Cards for FreeCell](https://rosettacode.org/wiki/Deal_cards_for_FreeCell) | Search |
| S93 | [PBN Standards (Portable Bridge Notation)](https://www.tistis.nl/pbn/pbn_standards.htm) | Search |
| S94 | [App Programming Guide for tvOS: iCloud Storage](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/iCloudStorage.html) | Search |
| S95 | [App Programming Guide for tvOS: Apple TV Remote](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/WorkingwiththeAppleTVRemote.html) | Search |
| S96 | [Apple: Learn Switch Control Through Gaming](https://developer.apple.com/documentation/accessibility/wwdc22_challenge_learn_switch_control_through_gaming) | Search |

### Additional Rule and Variant References

| ID | Source | Use |
| --- | --- | --- |
| S97 | [Fédération Française de Belote: Rules](https://www.ffbelote.org/reglements-de-la-belote-avec-ou-sans-annonce/) | Search |
| S98 | [ISPA World](https://ispa-world.org/) | Search |
| S99 | [Euchre Mate: Euchre House Rules](https://euchremate.com/blog/euchre-house-rules) | Search |
| S100 | [SpadesBid: Spades House Rules](https://spadesbid.com/house-rules/) | Search |
| S101 | [Bridge Winners: Accessibility for the Blind in ACBL-Land](https://bridgewinners.com/article/view/accessibility-for-the-blind-in-acbl-land/) | Search |
| S102 | [Parlett: The Penguin Book of Card Games (catalogue record)](https://obnb.uk/p14626417-the-penguin-book-of-card-games) | Search |
| S103 | [Frey: According to Hoyle](https://www.penguinrandomhouse.com/books/56441/according-to-hoyle-by-richard-l-frey/) | Search |
| S104 | [A Descriptive Bibliography of Edmond Hoyle](https://booksongaming.com/hoyle/bibliography/gameschron.html) | Search |
| S105 | [Apple swift-certificates (Apache-2.0)](https://github.com/apple/swift-certificates) | Metadata |
| S106 | [Solitaire Laboratory: FreeCell FAQ](https://www.solitairelaboratory.com/fcfaq.html) | Search |

Total: 106 registered sources, plus 94 game-page links in `CATALOGUE.md`.
