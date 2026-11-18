import Testing
import Persistence

@Suite("Persistence")
struct PersistenceTests {
    @Test func placeholderTypeIsReachable() {
        #expect(PersistencePlaceholder.name == "Persistence")
    }
}
