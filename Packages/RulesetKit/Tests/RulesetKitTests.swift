import RulesetKit
import Testing

@Suite("RulesetKit")
struct RulesetKitTests {
    @Test func placeholderTypeIsReachable() {
        #expect(RulesetKitPlaceholder.name == "RulesetKit")
    }
}
