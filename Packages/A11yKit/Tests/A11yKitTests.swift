import A11yKit
import Testing

@Suite("A11yKit")
struct A11yKitTests {
    @Test func placeholderName() {
        #expect(A11yKitPlaceholder.name == "A11yKit")
    }
}
