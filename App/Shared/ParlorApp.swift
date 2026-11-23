// Schema/Resolver are HostOnly SPI: the app is a host process (see PlaySession).
@_spi(HostOnly) import RulesetKit
import CardModel
import SwiftUI

/// Parlor app entry point, shared by the iOS and macOS targets (P0.2).
@main
struct ParlorApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
        }
    }
}

/// Temporary root (P3.7): lists the base rulesets and opens the dev play
/// screen for the chosen one. Replaced by the real table UI in P5.
struct LauncherView: View {
    /// The four base game stems (P3 corpus).
    static let games = [
        "hearts.standard", "euchre.standard",
        "contract-bridge.rubber", "cribbage.six-card",
    ]

    @State private var entry: Entry?

    var body: some View {
        NavigationStack {
            List(LauncherView.games, id: \.self) { name in
                Button(name) {
                    entry = Entry(ruleset: LauncherView.resolve(name))
                }
                .accessibilityIdentifier("game_\(name)")
            }
            .navigationTitle("Parlor dev")
            .navigationDestination(item: $entry) { entry in
                DevPlayView(ruleset: entry.ruleset, seed: entry.seed, humanSeat: Seat(0))
            }
        }
    }

    struct Entry: Hashable {
        let ruleset: ResolvedRuleset
        let seed: UInt64

        init?(ruleset: ResolvedRuleset?) {
            guard let ruleset else { return nil }
            self.ruleset = ruleset
            // Fixed dev seed for P3.7: the UI test replays the same deal.
            self.seed = 7
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.seed == rhs.seed && lhs.ruleset.hash == rhs.ruleset.hash
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ruleset.hash)
            hasher.combine(seed)
        }
    }

    /// Loads and resolves a ruleset from the app bundle. project.yml copies
    /// `Resources/Rulesets` as a folder reference, so files live under
    /// `Rulesets/` inside the bundle.
    static func resolve(_ name: String) -> ResolvedRuleset? {
        let url = Bundle.main.url(
            forResource: name, withExtension: "ruleset.json",
            subdirectory: "Rulesets")
            ?? Bundle.main.url(forResource: name, withExtension: "ruleset.json")
        guard let url else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let document = try? Schema.decodeRuleset(text) else { return nil }
        return try? Resolver.resolve(base: document)
    }
}

/// Build metadata exposed to unit tests.
public enum ParlorBuildInfo {
    public static let name = "Parlor"
}
