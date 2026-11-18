import Teaching
import Testing

@Suite("Teaching")
struct TeachingTests {
    @Test func placeholderTypeIsReachable() {
        #expect(TeachingPlaceholder.name == "Teaching")
    }
}
