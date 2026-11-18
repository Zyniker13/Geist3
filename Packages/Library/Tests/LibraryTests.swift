import Testing
import Library

@Suite("Library")
struct LibraryTests {
    @Test func placeholderTypeIsReachable() {
        #expect(LibraryPlaceholder.name == "Library")
    }
}
