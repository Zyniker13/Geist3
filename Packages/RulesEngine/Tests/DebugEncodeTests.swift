import Foundation
import Testing
@testable import RulesEngine
@_spi(HostOnly) import RulesEngine

@Suite("Debug — canonical encoding")
struct DebugEncodeTests {
    @Test func compareEncodings() throws {
        let engine = ToyGame.engine()
        let a = try ToyGame.play(engine: engine, seed: 12345)
        let b = try ToyGame.play(engine: engine, seed: 12345)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let da = try enc.encode(a)
        let db = try enc.encode(b)
        print("EQUAL STATES:", a == b)
        print("EQUAL BYTES:", da == db)
        if da != db {
            let sa = String(data: da, encoding: .utf8)!
            let sb = String(data: db, encoding: .utf8)!
            // Find first difference
            var i = 0
            let n = min(sa.count, sb.count)
            let aa = Array(sa), bb = Array(sb)
            while i < n && aa[i] == bb[i] { i += 1 }
            let lo = max(0, i - 60)
            print("DIFF at", i)
            print("A:", String(aa[lo..<min(aa.count, i + 60)]))
            print("B:", String(bb[lo..<min(bb.count, i + 60)]))
        }
    }
}
