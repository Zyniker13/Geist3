import Platform
import Testing

@Suite("Platform")
struct PlatformTests {
    @Test func placeholderTypeIsReachable() {
        #expect(PlatformPlaceholder.name == "Platform")
    }
}
