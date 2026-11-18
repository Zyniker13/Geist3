import Persistence
import Testing

@Suite("Persistence")
struct PersistenceTests {
    @Test func placeholderTypeIsReachable() {
        #expect(PersistencePlaceholder.name == "Persistence")
    }
}
