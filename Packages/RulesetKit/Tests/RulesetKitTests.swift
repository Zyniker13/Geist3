import Testing
import RulesetKit

@Suite("RulesetKit")
struct RulesetKitTests {
    @Test func placeholderTypeIsReachable() {
        #expect(RulesetKitPlaceholder.name == "RulesetKit")
    }
}
