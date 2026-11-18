import ParloriOS
import Testing

@Suite("Parlor iOS app")
struct ParlorIOSTests {
    @Test func buildInfoIsReachable() {
        #expect(ParlorBuildInfo.name == "Parlor")
    }
}
