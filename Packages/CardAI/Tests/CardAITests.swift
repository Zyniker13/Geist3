import Testing
import CardAI

@Suite("CardAI")
struct CardAITests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardAIPlaceholder.name == "CardAI")
    }
}
