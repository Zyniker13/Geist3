import Testing
import TableNet

@Suite("TableNet")
struct TableNetTests {
    @Test func placeholderTypeIsReachable() {
        #expect(TableNetPlaceholder.name == "TableNet")
    }
}
