import Foundation
import Testing

@testable import CardExpr

/// Parse-throughput tests (ROADMAP P2.1: parse time linear).
struct PerfTests {
    /// Parse time must scale linearly with input size: 4× the input takes
    /// roughly 4× the time.
    @Test func parseTimeIsLinear() throws {
        // A wide list literal keeps the tree depth constant (one list node
        // with N leaf children), so the measurement is parsing throughput
        // and never stresses recursive tree teardown on a small test stack.
        func listInput(_ n: Int) -> String {
            var s = "["
            s.reserveCapacity(n * 3 + 2)
            for i in 0..<n {
                if i > 0 { s += ", " }
                s += "a"
            }
            return s + "]"
        }
        func attos(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1_000_000_000_000_000_000 + duration.components.attoseconds
        }
        _ = try Parser().parse(listInput(2_000))  // warm-up
        let start1 = ContinuousClock.now
        _ = try Parser().parse(listInput(2_000))
        let t1 = ContinuousClock.now - start1
        let start2 = ContinuousClock.now
        _ = try Parser().parse(listInput(8_000))
        let t2 = ContinuousClock.now - start2
        // ratio > 1.5 and ratio < 10, in integer math (CONVENTIONS §5.4
        // bans floating point even in test helpers). Comparisons avoid
        // large multipliers so no Int64 multiplication can overflow.
        let small = attos(t1)
        let large = attos(t2)
        #expect(large > small + small / 2, "parse time ratio for 4x input below 1.5")
        #expect(large < small * 10, "parse time ratio for 4x input at 10 or more")
    }
}
