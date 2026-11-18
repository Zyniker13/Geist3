import Testing
import Accessibility

@Suite("Accessibility")
struct AccessibilityTests {
    @Test func placeholderTypeIsReachable() {
        #expect(AccessibilityPlaceholder.name == "Accessibility")
    }
}
