import Testing
import Teaching

@Suite("Teaching")
struct TeachingTests {
    @Test func placeholderTypeIsReachable() {
        #expect(TeachingPlaceholder.name == "Teaching")
    }
}
