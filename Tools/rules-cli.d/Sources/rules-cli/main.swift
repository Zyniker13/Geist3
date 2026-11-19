// rules-cli — the Parlor ruleset tool (§11.4).
//
//   rules-cli validate                 run the 60-case corpus, compare against
//                                      docs/rulesets/corpus/expected.tsv
//   rules-cli validate FILE...         validate ruleset files, report issues
//   rules-cli fmt [--write] FILE...    re-emit each file in canonical form
//   rules-cli schema [--out DIR] [--check]
//                                      write (or verify) the exported JSON
//                                      Schemas (draft 2020-12)
//   rules-cli simulate [--seeds N] [--seed S] [--quiet] FILE...
//                                      run N seeded random-legal deals of each
//                                      ruleset; report faults and the rule
//                                      exercise report
//
// Exit status: 0 clean, 1 any error/mismatch, 2 usage error.

import Foundation
@_spi(HostOnly) @_spi(Tools) import RulesetKit

func repoRoot() -> URL? {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while dir.pathComponents.count > 1 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/plan").path) {
            return dir
        }
        dir.deleteLastPathComponent()
    }
    return nil
}

/// P2.9: write (or verify) the exported JSON Schemas. Freshness check is a
/// byte comparison of both normalized pretty forms, so regenerating never
/// churns whitespace-only diffs and CI fails on real drift.
func runSchema(out: URL, check: Bool) -> Int {
    let files: [(String, JSON)] = [
        ("ruleset.schema.json", SchemaExport.rulesetSchema()),
        ("lesson.schema.json", SchemaExport.lessonSchema()),
    ]
    var ok = true
    for (name, schema) in files {
        let text = schema.prettyString() + "\n"
        let target = out.appendingPathComponent(name)
        if check {
            guard let existing = try? String(contentsOf: target, encoding: .utf8) else {
                print("\(name): missing — run `rules-cli schema` to regenerate")
                ok = false
                continue
            }
            if existing == text {
                print("\(name): up to date")
            } else {
                print("\(name): stale — run `rules-cli schema` to regenerate")
                ok = false
            }
        } else {
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
                print("wrote \(target.path)")
            } catch {
                print("\(name): error: \(error)")
                ok = false
            }
        }
    }
    return ok ? 0 : 1
}

func printIssue(_ issue: ValidationIssue) {
    print("  [\(issue.code)] \(issue.pointer): \(issue.message)")
}

func validateText(_ text: String, byteCount: Int, name: String) -> Bool {
    let report = RulesetValidator.validate(text: text, byteCount: byteCount)
    if report.errors.isEmpty {
        for warning in report.warnings {
            print("\(name): warning")
            printIssue(warning)
        }
        print("\(name): passed")
        return true
    }
    print("\(name): \(report.errors.count) error\(report.errors.count == 1 ? "" : "s")")
    for issue in report.errors { printIssue(issue) }
    return false
}

func runCorpus(_ corpusDir: URL) -> Int {
    let manifestURL = corpusDir.appendingPathComponent("expected.tsv")
    guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
        print("error: no expected.tsv in \(corpusDir.path)")
        return 2
    }
    var pass = 0
    var fail = 0
    for line in manifest.split(separator: "\n") {
        if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
            continue
        }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 3 else { continue }
        let (name, expectedCode, fragment) = (cols[0], cols[1], cols[2])
        let url = corpusDir.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("FAIL \(name) (missing file)")
            fail += 1
            continue
        }
        let report = RulesetValidator.validate(text: text, byteCount: text.utf8.count)
        if name.hasPrefix("_") {  // canary: the valid template
            if report.errors.isEmpty {
                pass += 1
            } else {
                print("FAIL \(name) (canary must validate clean)")
                for issue in report.errors { printIssue(issue) }
                fail += 1
            }
            continue
        }
        let matched = report.errors.first { issue in
            issue.code == expectedCode && issue.message.contains(fragment)
        }
        if matched != nil {
            pass += 1
        } else {
            print(
                "FAIL \(name): expected \(expectedCode) with '\(fragment)'; got "
                    + report.errors.map { "\($0.code)" }.joined(separator: ", "))
            fail += 1
        }
    }
    print("corpus: \(pass) passed, \(fail) failed")
    return fail == 0 ? 0 : 1
}

func validateFiles(_ urls: [URL]) -> Int {
    var ok = true
    for url in urls {
        guard let data = try? Data(contentsOf: url) else {
            print("error: cannot read \(url.path)")
            ok = false
            continue
        }
        let text = String(decoding: data, as: UTF8.self)
        let good = validateText(text, byteCount: data.count, name: url.lastPathComponent)
        ok = ok && good
    }
    return ok ? 0 : 1
}

func fmt(_ urls: [URL], write: Bool) -> Int {
    var ok = true
    for url in urls {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("error: cannot read \(url.path)")
            ok = false
            continue
        }
        do {
            let json = try JSONParser.parse(text)
            let formatted = json.prettyString() + "\n"
            if write {
                try formatted.write(to: url, atomically: true, encoding: .utf8)
            } else {
                print(formatted, terminator: "")
            }
        } catch {
            print("error: \(url.lastPathComponent) is not valid JSON: \(error)")
            ok = false
        }
    }
    return ok ? 0 : 1
}

func simulate(_ urls: [URL], seeds: Int, firstSeed: UInt64, quiet: Bool) -> Int {
    var ok = true
    for url in urls {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            print("error: cannot read \(name)")
            ok = false
            continue
        }
        let text = String(decoding: data, as: UTF8.self)
        // A ruleset that does not validate clean is not simulated.
        let report = RulesetValidator.validate(text: text, byteCount: data.count)
        if !report.errors.isEmpty {
            print("\(name): \(report.errors.count) validation error\(report.errors.count == 1 ? "" : "s"); not simulated")
            for issue in report.errors { printIssue(issue) }
            ok = false
            continue
        }
        do {
            let document = try RulesetDocument(json: try JSONParser.parse(text), path: "$")
            let resolved = try Resolver.resolve(base: document)
            let simulator = try Simulator(ruleset: resolved)

            let started = Date()
            var faultSeeds: [UInt64: String] = [:]
            var maxActions = 0
            for offset in 0..<max(0, seeds) {
                let run = try simulator.runDeal(seed: firstSeed &+ UInt64(offset))
                maxActions = max(maxActions, run.actions)
                if let fault = run.faults.first { faultSeeds[run.seed] = fault }
            }
            let elapsed = Date().timeIntervalSince(started)

            // Reproducibility: an independent rerun of the first seed must
            // produce the identical final-state hash.
            let repeatRun = try simulator.runDeal(seed: firstSeed)
            let firstRun = try simulator.runDeal(seed: firstSeed)
            let reproducible = repeatRun.finalHash == firstRun.finalHash

            if !quiet {
                print(
                    "\(name): \(seeds) seeds in \(String(format: "%.2f", elapsed)) s"
                        + ", longest deal \(maxActions) actions"
                        + (reproducible ? ", repeat-seed reproducible" : ", REPEAT-SEED MISMATCH"))
                let unexercised = (try simulator.runDeal(seed: firstSeed)).unexercisedRules
                if !unexercised.isEmpty {
                    print("  unexercised declared rules: \(unexercised.joined(separator: ", "))")
                }
            }
            if !reproducible { ok = false }
            for (seed, fault) in faultSeeds.sorted(by: { $0.key < $1.key }) {
                print("\(name): FAULT seed \(seed): \(fault)")
                ok = false
            }
        } catch {
            print("\(name): error: \(error)")
            ok = false
        }
    }
    return ok ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: rules-cli validate [--corpus DIR] [FILE...] | fmt [--write] FILE...")
    exit(2)
}
let rest = Array(args.dropFirst())

switch command {
case "validate":
    var files: [URL] = []
    var corpusDir: URL?
    var i = 0
    while i < rest.count {
        if rest[i] == "--corpus", i + 1 < rest.count {
            corpusDir = URL(fileURLWithPath: rest[i + 1])
            i += 2
        } else {
            files.append(URL(fileURLWithPath: rest[i]))
            i += 1
        }
    }
    if files.isEmpty {
        let dir =
            corpusDir
            ?? repoRoot()?.appendingPathComponent("docs/rulesets/corpus")
        guard let dir else {
            print("error: corpus not found; pass --corpus DIR or run from the repository")
            exit(2)
        }
        exit(Int32(runCorpus(dir)))
    }
    exit(Int32(validateFiles(files)))
case "fmt":
    var write = false
    var files: [URL] = []
    for arg in rest {
        if arg == "--write" { write = true } else { files.append(URL(fileURLWithPath: arg)) }
    }
    guard !files.isEmpty else {
        print("usage: rules-cli fmt [--write] FILE...")
        exit(2)
    }
    exit(Int32(fmt(files, write: write)))
case "simulate", "sim":
    var seedCount = 200
    var firstSeed: UInt64 = 0
    var quiet = false
    var files: [URL] = []
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--seeds" where i + 1 < rest.count:
            guard let n = Int(rest[i + 1]), n >= 0 else {
                print("usage: --seeds expects a non-negative integer")
                exit(2)
            }
            seedCount = n
            i += 2
        case "--seed" where i + 1 < rest.count:
            guard let s = UInt64(rest[i + 1]) else {
                print("usage: --seed expects a non-negative integer")
                exit(2)
            }
            firstSeed = s
            i += 2
        case "--quiet":
            quiet = true
            i += 1
        default:
            files.append(URL(fileURLWithPath: rest[i]))
            i += 1
        }
    }
    guard !files.isEmpty else {
        print("usage: rules-cli simulate [--seeds N] [--seed S] [--quiet] FILE...")
        exit(2)
    }
    exit(Int32(simulate(files, seeds: seedCount, firstSeed: firstSeed, quiet: quiet)))
case "schema":
    var out = repoRoot()?.appendingPathComponent("Resources/Schemas")
        ?? URL(fileURLWithPath: "Resources/Schemas")
    var check = false
    var i = 0
    while i < rest.count {
        if rest[i] == "--out", i + 1 < rest.count {
            out = URL(fileURLWithPath: rest[i + 1])
            i += 2
        } else if rest[i] == "--check" {
            check = true
            i += 1
        } else {
            print("usage: rules-cli schema [--out DIR] [--check]")
            exit(2)
        }
    }
    exit(Int32(runSchema(out: out, check: check)))
case "conformance":
    // The conformance runner lands with P3 (recorded engine sessions).
    print("'conformance' arrives with P3.")
    exit(2)
case "resolve", "replay", "fuzz":
    print("rules-cli \(command): not implemented yet (lands in P3).")
    exit(1)
default:
    print("unknown command '\(command)'")
    exit(2)
}
