// The host side of the engine's expression boundary (ARCHITECTURE §7.5).
//
// The engine owns no evaluator: mechanics call host expressions through
// `EvalContext.eval`, and this runtime turns each `EvalCall` plus the
// engine's `GameState` into an `EvaluationEnvironment` and evaluates the
// expression deterministically. Compilation goes through the same
// `TypeContextFactory` validation used, so a rule that passed stage E
// type-checks identically at the table; per-call contextual bindings are
// typed `any` because stage E already pinned each site's real types.
//
// Determinism (CONVENTIONS §5): the environment is a pure function of the
// state snapshot and the document; the compile cache is keyed by source
// text and contextual names, never by call order.
//
// Environment construction and value conversion live in sibling files
// (`ExpressionRuntime+Environment.swift`, `ExpressionRuntime+Values.swift`).

import CardExpr
import CardModel
import Foundation
@_spi(HostOnly) import RulesEngine

@_spi(HostOnly)
public final class ExpressionRuntime: @unchecked Sendable {

    // MARK: static parts (a pure function of the resolved document)

    /// The shared type context, identical to the one validation built.
    /// Internal so the sibling extensions can read it.
    let context: TypeContext
    /// Seat spellings in seat order (§7.3 `seats()`).
    let seats: [Value]
    /// Team spellings in team order (§7.3 `teams()`).
    let teams: [Value]
    /// Which team each seat belongs to (`team(s)`); empty for team-less
    /// and dynamic layouts until a mechanic assigns sides.
    let teamOfSeat: [String: String]
    /// Seat spellings as raw strings, in seat order.
    let seatSpellings: [String]
    /// Team spellings as raw strings, in team order.
    let teamSpellings: [String]
    /// Lookup tables from spelling to raw index position (§7.3).
    let seatIndex: [String: Int]
    let teamIndex: [String: Int]
    /// Declared rank orders (`rankIndex`).
    let orders: [String: [String]]
    /// Resolved option values (`options.<id>`).
    let optionValues: [String: Value]
    let seatCount: Int

    /// Compile cache: source + contextual names → typed expression.
    private struct CompiledKey: Hashable {
        var pointer: String
        var source: String
        var contextual: [String]
    }

    private let lock = NSLock()
    private var compiled: [CompiledKey: TypedExpr] = [:]

    // MARK: init

    /// Builds the runtime. `seatCount` is the resolved player count the
    /// builder already computed; option values come from each option's
    /// resolved `value` (the table's choice or the merged default, §8.1).
    public init(doc: RulesetDocument, seatCount: Int) throws(SimulationError) {
        self.seatCount = seatCount

        let names = NameTables(doc)
        let (context, issues) = TypeContextFactory.make(doc: doc, names: names)
        guard issues.isEmpty else {
            // The document was validated before it reached the builder;
            // an issue here means the factory drifted from stage E.
            throw
                SimulationError
                .unsupported("expression context build failed: \(issues[0].message)")
        }
        self.context = context

        let playerSpec = doc.players
        var spellings: [String] = []
        if let seatNames = playerSpec?.seatNames, seatNames.count == seatCount {
            spellings = seatNames
        } else {
            spellings = (1...max(seatCount, 0)).map { "S\($0)" }
        }
        self.seats = spellings.map { .string($0) }
        self.seatSpellings = spellings
        self.seatIndex = Self.indexTable(spellings)

        // Team layout (§4.3, §5.4): partnershipOpposite seats alternate
        // between two teams; a team is spelled by concatenating the seat
        // names of its members when seat names exist ("NS", "EW"), else
        // generically. Dynamic layouts get generic names; mechanics that
        // resolve sides (auction results) bind them per deal.
        var teams: [Value] = []
        var teamNames: [String] = []
        var teamOfSeat: [String: String] = [:]
        if playerSpec?.teams == "partnershipOpposite", seatCount >= 2, seatCount % 2 == 0 {
            for parity in 0..<2 {
                var members: [String] = []
                for index in stride(from: parity, to: seatCount, by: 2) {
                    members.append(spellings[index])
                }
                let spelling = members.joined()
                teams.append(.string(spelling))
                teamNames.append(spelling)
                for member in members { teamOfSeat[member] = spelling }
            }
        }
        self.teams = teams
        self.teamOfSeat = teamOfSeat
        self.teamSpellings = teamNames
        self.teamIndex = Self.indexTable(teamNames)

        var orders: [String: [String]] = [:]
        for field in doc.orders ?? [] {
            if case .array(let items) = field.value {
                orders[field.key] = items.compactMap { item in
                    if case .string(let s) = item { return s }
                    return nil
                }
            }
        }
        self.orders = orders

        var optionValues: [String: Value] = [:]
        for option in doc.options ?? [] {
            let json = option.value ?? option.defaultValue
            optionValues[option.id] = Self.value(from: json)
        }
        self.optionValues = optionValues
    }

    /// The eval closure the builder installs into the engine.
    public func evaluate(
        _ call: EvalCall, _ state: GameState
    ) throws(EvalFailure) -> EvalValue {
        let typed = try compile(call)
        var evaluator = Evaluator(context: context)
        let env = environment(for: call, state: state)
        do {
            let value = try evaluator.evaluate(
                typed, in: env, ruleId: call.ruleId, pointer: call.pointer)
            return Self.evalValue(from: value)
        } catch {
            throw Self.failure(from: error, pointer: call.pointer)
        }
    }

    // MARK: compilation

    private func compile(_ call: EvalCall) throws(EvalFailure) -> TypedExpr {
        // Contextual names are part of the key: the same source under
        // different mechanic bindings compiles differently.
        let names = call.contextual.keys.sorted()
        let key = CompiledKey(
            pointer: call.pointer, source: call.source, contextual: names)
        lock.lock()
        if let cached = compiled[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var contextual: [String: ExprType] = context.contextual
        for name in names {
            // Stage E pinned each site's real contextual types; the
            // runtime re-checks permissively so a validated expression
            // always recompiles (§7.5). The binding's own kind supplies
            // the type: the evaluator resolves these names from this
            // call's bindings, so the checker must see them too, or a
            // let-bound name falls through to the canonical spelling
            // (§7.3) and disagrees with run time.
            contextual[name] = Self.bindingType(call.contextual[name] ?? .null)
        }
        var callContext = context
        callContext.contextual = contextual
        var checker = TypeChecker(context: callContext)
        do {
            // Check in a scope carrying this call's contextual bindings:
            // the evaluator resolves those names at run time, so the
            // checker must see them too (a let-bound name shadows the
            // canonical spelling, §7.3/§7.5).
            let typed = try checker.check(
                try Parser().parse(call.source).ast, in: Scope(contextual: contextual))
            lock.lock()
            compiled[key] = typed
            lock.unlock()
            return typed
        } catch let error as ParseError {
            throw .fault(pointer: call.pointer, detail: "does not parse: \(error)")
        } catch let error as TypeError {
            throw .fault(pointer: call.pointer, detail: error.message)
        } catch {
            throw .fault(pointer: call.pointer, detail: "\(error)")
        }
    }
}
