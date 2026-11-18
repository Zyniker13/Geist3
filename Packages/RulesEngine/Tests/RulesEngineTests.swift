import Testing
import RulesEngine

@Suite("RulesEngine")
struct RulesEngineTests {
    @Test func placeholderTypeIsReachable() {
        #expect(RulesEnginePlaceholder.name == "RulesEngine")
    }
}
