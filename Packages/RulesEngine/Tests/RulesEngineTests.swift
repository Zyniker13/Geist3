import RulesEngine
import Testing

@Suite("RulesEngine")
struct RulesEngineTests {
    @Test func placeholderTypeIsReachable() {
        #expect(RulesEnginePlaceholder.name == "RulesEngine")
    }
}
