import Library
import Testing

@Suite("Library")
struct LibraryTests {
    @Test func placeholderTypeIsReachable() {
        #expect(LibraryPlaceholder.name == "Library")
    }
}
