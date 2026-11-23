// Dev play screen (P3.7): a plain SwiftUI table, deliberately not the final
// design. It exists to exercise the engine end-to-end — observation, legal
// intents, rule explanations — and to host the P3.7 XCUITest that plays one
// full deal of each base game.

import CardModel
import RulesEngine
// EngineBuilder is HostOnly SPI: the app is a host process (see PlaySession).
@_spi(HostOnly) import RulesetKit
import SwiftUI

struct DevPlayView: View {
    @StateObject private var model: DevPlayModel

    init(ruleset: ResolvedRuleset, seed: UInt64, humanSeat: Seat) {
        _model = StateObject(wrappedValue: DevPlayModel(ruleset: ruleset, seed: seed, humanSeat: humanSeat))
    }

    /// Hosting hook for previews and tests that already hold a session.
    init(session: PlaySession) {
        _model = StateObject(wrappedValue: DevPlayModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            eventLog
            zones
            actionArea
        }
        .padding()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parlor dev — \(model.rulesetName)")
                .font(.headline)
            Text("You are \(model.humanName). \(model.phaseLine)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.matchOver {
                Text("Match over.")
                    .font(.title3.weight(.semibold))
            }
            Text("Deals completed: \(model.session.dealsCompleted)")
                .font(.caption)
                .accessibilityIdentifier("dealsCounter")
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last events").font(.caption.weight(.semibold))
            ForEach(Array(model.eventLines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).accessibilityIdentifier("eventLine")
            }
        }
        .accessibilityIdentifier("eventLog")
    }

    private var zones: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.zoneLines, id: \.name) { zone in
                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.name).font(.caption.weight(.semibold))
                    Text(zone.cards).font(.body.monospaced())
                }
                .accessibilityIdentifier("zone_\(zone.name)")
            }
        }
        .accessibilityIdentifier("zones")
    }

    @ViewBuilder
    private var actionArea: some View {
        if model.waitingOnHuman {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your move").font(.caption.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(Array(model.legalButtons.enumerated()), id: \.offset) { index, button in
                        Button(button.label) {
                            model.play(at: index)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("intent_\(index)")
                    }
                }
            }
            .accessibilityIdentifier("actionArea")
        } else {
            Text("Waiting…").font(.caption).accessibilityIdentifier("waiting")
        }
        if let violation = model.violationText {
            Text(violation)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("violation")
        }
    }
}

@MainActor
final class DevPlayModel: ObservableObject {
    let session: PlaySession
    @Published private(set) var revision = 0

    init(ruleset: ResolvedRuleset, seed: UInt64, humanSeat: Seat) {
        session = try! PlaySession(ruleset: ruleset, seed: seed, humanSeat: humanSeat)
    }

    init(session: PlaySession) {
        self.session = session
    }

    var rulesetName: String { session.rulesetName }
    var humanName: String { session.seatNames[session.humanSeat.raw] }
    var matchOver: Bool { session.matchOver }
    var waitingOnHuman: Bool { session.waitingOnHuman }
    var violationText: String? { session.lastViolation }

    var phaseLine: String {
        let observation = session.observation
        let pending = observation.phase.pendingSeats
        let names = session.seatNames
        let waiting = (0..<names.count)
            .filter { pending.contains(Seat($0)) }
            .map { names[$0] }
        return "phase \(observation.phase.phaseID), waiting on \(waiting.joined(separator: ", "))"
    }

    var eventLines: [String] {
        session.lastEvents.map(Self.eventLine)
    }

    var zoneLines: [(name: String, cards: String)] {
        let observation = session.observation
        return observation.zones
            .sorted { $0.key < $1.key }
            .map { key, zone -> (String, String) in
                switch zone {
                case .visible(let cards):
                    return (key, cards.map { $0.face.id }.joined(separator: " "))
                case .hidden(let count, let known):
                    let knownText = known.map { $0.face.id }.joined(separator: " ")
                    return (key, knownText.isEmpty ? "\(count) face-down" : knownText)
                }
            }
    }

    var legalButtons: [(label: String, intent: ActionIntent)] {
        let observation = session.observation
        return observation.legal.map { intent in
            (label: Self.label(intent), intent: intent)
        }
    }

    func play(at index: Int) {
        let intents = session.observation.legal
        guard intents.indices.contains(index) else { return }
        session.play(intents[index])
        revision += 1
    }

    // MARK: - Rendering helpers

    static func label(_ intent: ActionIntent) -> String {
        switch intent {
        case .play(let id): return "Play #\(id.raw)"
        case .call(let tag): return "Call \(tag)"
        case .pass(let cards): return "Pass \(cards.count)"
        case .discard(let cards): return "Discard \(cards.count)"
        case .drawFrom(let zone): return "Draw \(zone)"
        case .meld(let cards): return "Meld \(cards.count)"
        case .choose(let tag): return "Choose \(tag)"
        case .claim(let n): return "Claim \(n)"
        case .acceptClaim(let ok): return ok ? "Accept claim" : "Reject claim"
        case .cut(let depth): return "Cut \(depth)"
        case .count(let points): return "Count \(points)"
        case .confirm: return "Confirm"
        }
    }

    static func eventLine(_ event: GameEvent) -> String {
        switch event {
        case .dealt(let seat, let cards): return "dealt \(cards.count) to \(seat.raw)"
        case .passed(let from, let to, let cards): return "\(from.raw)→\(to.raw) passed \(cards.count)"
        case .received(let seat, let count): return "\(seat.raw) received \(count)"
        case .called(let seat, let call): return "\(seat.raw) called \(call)"
        case .contractSet(let text): return "contract \(text)"
        case .cardPlayed(let seat, let card): return "\(seat.raw) played \(card.face.id)"
        case .trickWon(let seat, let cards): return "\(seat.raw) won \(cards.count)"
        case .cardsMoved(let from, let to, let count): return "\(from)→\(to) moved \(count)"
        case .revealed(let zone, let cards): return "revealed \(zone) (\(cards.count))"
        case .scored(let seat, let points, let reason, _):
            return "score \(points) to \(seat.map { "\($0.raw)" } ?? "-") (\(reason))"
        case .phaseStarted(let id): return "phase \(id)"
        case .dealEnded: return "deal ended"
        case .matchEnded: return "match ended"
        case .emitted(let name): return "signal \(name)"
        }
    }
}
