import Accessibility
import Testing

@Suite("Accessibility")
struct AccessibilityTests {
    @Test func placeholderTypeIsReachable() {
        #expect(AccessibilityPlaceholder.name == "Accessibility")
    }
}
