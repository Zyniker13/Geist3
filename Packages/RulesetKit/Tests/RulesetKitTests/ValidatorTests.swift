// P2.7 acceptance: the validator's stages B–F and the 60-case corpus.
//
// The reference rulesets are the ground truth for "valid": they must pass
// stages B–F with zero errors. The corpus (docs/rulesets/corpus) holds 60
// broken rulesets, ten per error class, each expected to fail with a
// specific code and a message fragment.

import Foundation
import Testing

@testable import RulesetKit

struct ValidatorTests {
    /// Walks up from this file until it finds the repository root marker,
    /// so the path works regardless of what base SwiftPM gives `#filePath`.
    static let repoRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/plan").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        fatalError("repository root not found above \(#filePath)")
    }()

    static let rulesetFiles = [
        "hearts.standard.ruleset.json",
        "contract-bridge.rubber.ruleset.json",
        "cribbage.six-card.ruleset.json",
        "euchre.standard.ruleset.json",
    ]

    func read(_ relative: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: reference rulesets validate clean

    // MARK: reference rulesets validate clean

    @Test func referenceRulesetsValidateClean() throws {
        for name in Self.rulesetFiles {
            let text = try read("docs/plan/rulesets/\(name)")
            let report = RulesetValidator.validate(
                text: text, byteCount: text.utf8.count)
            #expect(
                report.errors.isEmpty,
                "\(name) failed validation:\n\(report.errors.map { "\($0)" }.joined(separator: "\n"))")
        }
    }

    // MARK: corpus (60 broken rulesets, ten per class)

    /// Every corpus case must fail with exactly the expected error code and
    /// a message containing the manifest's fragment. Files starting with "_"
    /// are canaries (the valid template) and must produce no errors.
    @Test func corpusMatchesExpectations() throws {
        let corpusURL = Self.repoRoot.appendingPathComponent("docs/rulesets/corpus")
        let manifest = try String(
            contentsOf: corpusURL.appendingPathComponent("expected.tsv"), encoding: .utf8)
        var checked = 0
        for line in manifest.split(separator: "\n") {
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard cols.count >= 3 else {
                Issue.record("malformed manifest line: \(line)")
                continue
            }
            let (name, expectedCode, fragment) = (cols[0], cols[1], cols[2])
            let text = try String(
                contentsOf: corpusURL.appendingPathComponent(name), encoding: .utf8)
            let report = RulesetValidator.validate(text: text, byteCount: text.utf8.count)
            if name.hasPrefix("_") {
                #expect(
                    report.errors.isEmpty,
                    "\(name) is a canary and must validate clean: \(report.errors)")
                continue
            }
            let matched = report.errors.first { issue in
                issue.code == expectedCode && issue.message.contains(fragment)
            }
            let got = report.errors.map { "\($0.code) \($0.pointer)" }.joined(separator: "; ")
            #expect(
                matched != nil,
                "\(name): expected \(expectedCode) with '\(fragment)'; got \(got)"
            )
            checked += 1
        }
        #expect(checked == 60, "expected 60 corpus cases, checked \(checked)")
    }
}
