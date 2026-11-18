import ParlorMacOS
import Testing

@Suite("Parlor macOS app")
struct ParlorMacOSTests {
    @Test func buildInfoIsReachable() {
        #expect(ParlorBuildInfo.name == "Parlor")
    }
}
