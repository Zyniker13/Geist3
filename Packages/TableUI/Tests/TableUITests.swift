import TableUI
import Testing

@Suite("TableUI")
struct TableUITests {
    @Test func placeholderTypeIsReachable() {
        #expect(TableUIPlaceholder.name == "TableUI")
    }
}
