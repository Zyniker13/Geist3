import Testing
import Platform

@Suite("Platform")
struct PlatformTests {
    @Test func placeholderTypeIsReachable() {
        #expect(PlatformPlaceholder.name == "Platform")
    }
}
