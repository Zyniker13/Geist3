// rules-cli — the Parlor ruleset tool (§11.4).
//
//   rules-cli validate                 run the 60-case corpus, compare against
//                                      docs/rulesets/corpus/expected.tsv
//   rules-cli validate FILE...         validate ruleset files, report issues
//   rules-cli fmt [--write] FILE...    re-emit each file in canonical form
//
// Exit status: 0 clean, 1 any error/mismatch, 2 usage error.

import Foundation
import RulesetKit

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
case "simulate", "conformance":
    // P2.8 lands the simulator and conformance runner.
    print("'\(command)' arrives with P2.8 (simulator).")
    exit(2)
case "resolve", "replay", "fuzz":
    print("rules-cli \(command): not implemented yet (lands in P3).")
    exit(1)
default:
    print("unknown command '\(command)'")
    exit(2)
}
