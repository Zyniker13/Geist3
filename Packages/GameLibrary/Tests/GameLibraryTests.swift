import Testing
import GameLibrary

@Suite("GameLibrary")
struct GameLibraryTests {
    @Test func placeholderTypeIsReachable() {
        #expect(GameLibraryPlaceholder.name == "GameLibrary")
    }
}
