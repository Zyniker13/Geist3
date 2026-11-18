import Testing
import CardExpr

@Suite("CardExpr")
struct CardExprTests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardExprPlaceholder.name == "CardExpr")
    }
}
