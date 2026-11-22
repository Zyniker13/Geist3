// The `rules-cli conformance` runner (P3.4): cross-check the conformance
// suites against the rule documents and write docs/CONFORMANCE.md
// (CONVENTIONS §6, ROADMAP P3.4).
//
// Coverage evidence comes from the suite source files, not random-legal
// simulation: the Simulator's `exercised` set collects rule ids only from
// `.scored` events and `.illegal` violations, so structural rules (the
// deal, the auction, the show) never register in a sim run. The tagged
// suites are the coverage evidence; this command verifies that every
// rule id declared by a game's RULES document appears in its suite file
// at least once, then emits the table.
//
// Scope is the four base games' RULES documents. Variant overlays
// declare extra ids (e.g. CRB-V.1) that no RULES document numbers; they
// are out of scope here and reported as extras (not failures) if a suite
// references them.
//
// The output is fully deterministic: no timestamps, no environment
// values. The Commit column is the last commit that touched each suite
// file (stable across checkouts), `--` when git cannot answer.

import Foundation

private let idPattern = "[A-Z]{3}-[0-9]+\\.[0-9]+"

private struct ConformanceGame {
    let label: String
    let docPath: String
    let suitePath: String
    /// Directory holding this game's committed golden replay files
    /// (parlor.replay/1); empty until that game's replays land (P3.5).
    let replayDir: String?
}

private let games: [ConformanceGame] = [
    ConformanceGame(
        label: "Hearts", docPath: "docs/rules/RULES-hearts.md",
        suitePath: "Packages/RulesetKit/Tests/RulesetKitTests/ConformanceHearts.swift",
        replayDir: "Packages/RulesetKit/Tests/Fixtures/Replays"),
    ConformanceGame(
        label: "Euchre", docPath: "docs/rules/RULES-euchre.md",
        suitePath: "Packages/RulesetKit/Tests/RulesetKitTests/ConformanceEuchre.swift",
        replayDir: "Packages/RulesetKit/Tests/Fixtures/Replays"),
    ConformanceGame(
        label: "Bridge", docPath: "docs/rules/RULES-contract-bridge.md",
        suitePath: "Packages/RulesetKit/Tests/RulesetKitTests/ConformanceBridge.swift",
        replayDir: "Packages/RulesetKit/Tests/Fixtures/Replays"),
    ConformanceGame(
        label: "Cribbage", docPath: "docs/rules/RULES-cribbage.md",
        suitePath: "Packages/RulesetKit/Tests/RulesetKitTests/ConformanceCribbage.swift",
        replayDir: "Packages/RulesetKit/Tests/Fixtures/Replays"),
]

/// Number of committed golden replay files for one game. The fixture
/// directory is shared by the four base games; each file is named
/// `<game-slug>-NN.json`, so count by prefix.
private func goldenCount(root: URL, game: ConformanceGame) -> String {
    guard let replayDir = game.replayDir else { return "0 (pending P3.5)" }
    let dir = root.appendingPathComponent(replayDir, isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
        return "0 (missing \(replayDir))"
    }
    let prefixes: [String: String] = [
        "hearts": "hearts-standard-", "euchre": "euchre-standard-",
        "bridge": "contract-bridge-rubber-", "cribbage": "cribbage-six-card-",
    ]
    guard let prefix = prefixes[game.label.lowercased()] else { return "0" }
    let count = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.count
    return count >= 20 ? "\(count) ok" : "\(count) (need 20; pending P3.5)"
}

private func ruleIDs(in text: String) -> Set<String> {
    guard let regex = try? NSRegularExpression(pattern: idPattern) else { return [] }
    var ids: Set<String> = []
    let range = NSRange(text.startIndex..., in: text)
    for match in regex.matches(in: text, range: range) {
        guard let r = Range(match.range, in: text) else { continue }
        ids.insert(String(text[r]))
    }
    return ids
}

private func lastCommit(root: URL, relPath: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "log", "-1", "--format=%h", "--", relPath]
    process.currentDirectoryURL = root
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do {
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let sha = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? "--" : sha
    } catch {
        return "--"
    }
}

/// Builds the generated document. Returns the text and, separately, the
/// coverage failures (missing declared ids per game) so the caller can
/// exit nonzero while still writing the failing table.
private func document(root: URL) -> (text: String, failures: [String]) {
    var rows: [String] = []
    var failures: [String] = []
    var extras: [String] = []

    for game in games {
        let docText = (try? String(contentsOf: root.appendingPathComponent(game.docPath), encoding: .utf8)) ?? ""
        let suiteText = (try? String(contentsOf: root.appendingPathComponent(game.suitePath), encoding: .utf8)) ?? ""
        if docText.isEmpty || suiteText.isEmpty {
            failures.append("\(game.label): missing \(docText.isEmpty ? game.docPath : game.suitePath)")
            continue
        }
        let declared = ruleIDs(in: docText)
        let covered = ruleIDs(in: suiteText)
        let missing = declared.subtracting(covered).sorted()
        let extra = covered.subtracting(declared).sorted()
        if !extra.isEmpty {
            extras.append(
                "\(game.label): \(extra.count) id(s) outside the RULES doc: "
                    + extra.joined(separator: ", "))
        }

        let result: String
        if missing.isEmpty {
            result = "pass"
        } else {
            result = "FAIL (missing: \(missing.joined(separator: ", ")))"
            failures.append(
                "\(game.label): \(missing.count) declared id(s) untested: "
                    + missing.joined(separator: ", "))
        }
        let sha = lastCommit(root: root, relPath: game.suitePath)
        let goldens = goldenCount(root: root, game: game)
        rows.append(
            "| \(game.label) | \(declared.count) | \(covered.count) | \(goldens) | \(result) | \(sha) |")
    }

    var text = ""
    text += "# CONFORMANCE\n"
    text += "\n"
    text += "Purpose: per-game rule-ID coverage (every numbered rule in"
    text += " `docs/rules/RULES-<game>.md` has at least one tagged test) and"
    text += " golden-replay results, per `docs/plan/CONVENTIONS.md` §6."
    text += " Written by `make conformance`.\n"
    text += "\n"
    text += "| Game | Rule IDs | Covered | Golden replays | Result | Commit |\n"
    text += "| --- | --- | --- | --- | --- | --- |\n"
    text += rows.joined(separator: "\n")
    text += rows.isEmpty ? "" : "\n"
    text += "\n"
    text += "Coverage counts rule ids in the suite sources (the tagged tests"
    text += " are the evidence; random-legal simulation cannot exercise"
    text += " structural rules). Golden replays are committed fixture files"
    text += " replayed by GameReplayTests on macOS and, in CI, on the iOS"
    text += " simulator; `20 ok` means the full per-game set is present.\n"
    return (text, failures)
}

func runConformance(check: Bool) -> Int {
    guard let root = repoRoot() else {
        print("error: repository root not found (no docs/plan); run from the repository")
        return 2
    }
    let target = root.appendingPathComponent("docs/CONFORMANCE.md")
    let (text, failures) = document(root: root)
    if check {
        guard let existing = try? String(contentsOf: target, encoding: .utf8) else {
            print("docs/CONFORMANCE.md: missing — run `make conformance` to regenerate")
            return 1
        }
        if existing == text {
            print("docs/CONFORMANCE.md: up to date")
        } else {
            print("docs/CONFORMANCE.md: stale — run `make conformance` to regenerate")
            return 1
        }
    } else {
        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
            print("wrote \(target.path)")
        } catch {
            print("error: cannot write docs/CONFORMANCE.md: \(error)")
            return 1
        }
    }
    for failure in failures { print("conformance: FAIL \(failure)") }
    if failures.isEmpty {
        print("conformance: all declared rule ids covered")
    }
    return failures.isEmpty ? 0 : 1
}
