import Testing
import ParloriOS

@Suite("Parlor iOS app")
struct ParlorIOSTests {
    @Test func buildInfoIsReachable() {
        #expect(ParlorBuildInfo.name == "Parlor")
    }
}
