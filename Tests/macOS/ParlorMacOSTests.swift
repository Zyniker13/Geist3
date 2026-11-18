import Testing
import ParlorMacOS

@Suite("Parlor macOS app")
struct ParlorMacOSTests {
    @Test func buildInfoIsReachable() {
        #expect(ParlorBuildInfo.name == "Parlor")
    }
}
