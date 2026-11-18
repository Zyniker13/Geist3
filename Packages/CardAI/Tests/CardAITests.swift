import CardAI
import Testing

@Suite("CardAI")
struct CardAITests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardAIPlaceholder.name == "CardAI")
    }
}
