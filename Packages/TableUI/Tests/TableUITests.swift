import Testing
import TableUI

@Suite("TableUI")
struct TableUITests {
    @Test func placeholderTypeIsReachable() {
        #expect(TableUIPlaceholder.name == "TableUI")
    }
}
