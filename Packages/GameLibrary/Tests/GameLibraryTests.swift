import GameLibrary
import Testing

@Suite("GameLibrary")
struct GameLibraryTests {
    @Test func placeholderTypeIsReachable() {
        #expect(GameLibraryPlaceholder.name == "GameLibrary")
    }
}
