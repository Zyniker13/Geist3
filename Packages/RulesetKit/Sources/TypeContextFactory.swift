// The TypeContext every expression check and host evaluation builds from
// a resolved document (§7.5). Stage E (validation) and the expression
// runtime (§7.5 host evaluation) MUST construct identical contexts so a
// rule validated before play type-checks the same way at the table; the
// factory is the single point that guarantees that.

import CardExpr

// MARK: - Shared context construction

enum TypeContextFactory {

    /// Builds the shared context. `issues` collects option-type and
    /// def-signature problems: validation appends them to its issue list;
    /// the runtime treats any as a bug (the document was validated first).
    static func make(
        doc: RulesetDocument, names: NameTables
    ) -> (context: TypeContext, issues: [ValidationIssue]) {
        var issues: [ValidationIssue] = []

        var options: [String: ExprType] = [:]
        for option in doc.options ?? [] {
            do {
                // An enum option holds one of its declared string values.
                let typeName = option.type == "enum" ? "string" : option.type
                options[option.id] = try RulesetTypeNames.parse(typeName)
            } catch {
                issues.append(
                    ValidationIssue(
                        .error, "type/bad-type", "/options/\(option.id)/type",
                        "'\(option.type)' is not a known type name. "
                            + "Use int, bool, string, card, seat, team, or list<...>."))
            }
        }

        var zones: [String: ZoneInfo] = [:]
        for zone in doc.zones ?? [] {
            let visibility: ZoneVisibility
            switch zone.visibility {
            case .named(let v): visibility = ZoneVisibility(rawValue: v) ?? .none
            case .seats: visibility = .owner
            }
            zones[zone.id] = ZoneInfo(id: zone.id, visibility: visibility)
        }

        var defs: [String: DefSignature] = [:]
        for field in doc.defs ?? [] {
            guard case .string(let bodyText) = field.value else {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)",
                        "A def maps its signature ('name(param: type, ...) -> result') to a "
                            + "body expression string."))
                continue
            }
            do {
                let header = try RulesetTypeNames.parseDefSignature(field.key)
                let parsed = try Parser().parse(bodyText)
                if parsed.nodeCount > Limits.maxASTNodes {
                    issues.append(
                        ValidationIssue(
                            .error, "limits/expression-size", "/defs/\(field.key)",
                            "The body of '\(header.name)' is \(parsed.nodeCount) AST nodes; the "
                                + "limit is \(Limits.maxASTNodes). Split it into smaller defs."))
                }
                defs[header.name] = DefSignature(
                    name: header.name, params: header.params, types: header.types,
                    result: header.result, body: parsed.ast)
            } catch let error as TypeError {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)",
                        "\(plain(error.message)) Fix the def's signature: "
                            + "'name(param: type, ...) -> resultType'."))
            } catch let error as ParseError {
                issues.append(
                    ValidationIssue(
                        .error, "type/parse-error", "/defs/\(field.key)",
                        "The body of '\(field.key)' does not parse: \(plain(error.description))"))
            } catch {
                issues.append(
                    ValidationIssue(
                        .error, "type/def-signature", "/defs/\(field.key)", "\(error)"))
            }
        }

        // Ambient names every ruleset may use: zones read bare (hearts passes
        // 'hand' where a card list is expected), and the reserved word
        // 'none' for "no value yet".
        var contextual: [String: ExprType] = [
            "none": .literalNull,
            // The all-pass action words (euchre redeals on a skipped deal).
            "redeal": .literalString,
        ]
        let reserved = Set(options.keys).union(defs.keys).union(names.vars.keys)
        for zone in doc.zones ?? [] where !reserved.contains(zone.id) {
            contextual[zone.id] = .list(.card)
        }

        let context = TypeContext(
            evaluation: .host, options: options, vars: names.vars, zones: zones,
            natives: nativeRegistry, defs: defs, contextual: contextual)
        return (context, issues)
    }

    /// Rewrites checker messages into plain language where the checker's
    /// wording is terse.
    private static func plain(_ message: String) -> String {
        var m = message
        if m.hasSuffix(" (§7.2)") || m.hasSuffix(" (§7.3)") || m.hasSuffix(" (§7.5)") {
            m = String(m.dropLast(6))
        }
        return m
    }
}
