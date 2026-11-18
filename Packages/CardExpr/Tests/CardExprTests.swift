import CardExpr
import Testing

@Suite("CardExpr")
struct CardExprTests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardExprPlaceholder.name == "CardExpr")
    }
}
