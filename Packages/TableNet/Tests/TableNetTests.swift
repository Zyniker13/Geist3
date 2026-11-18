import TableNet
import Testing

@Suite("TableNet")
struct TableNetTests {
    @Test func placeholderTypeIsReachable() {
        #expect(TableNetPlaceholder.name == "TableNet")
    }
}
