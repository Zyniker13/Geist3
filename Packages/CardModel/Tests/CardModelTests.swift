import CardModel
import Testing

@Suite("CardModel")
struct CardModelTests {
    @Test func placeholderTypeIsReachable() {
        #expect(CardModelPlaceholder.name == "CardModel")
    }
}
