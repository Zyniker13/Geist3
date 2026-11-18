import Testing
import CardModel

@Suite("CardModel")
struct CardModelTests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardModelPlaceholder.name == "CardModel")
    }
}
