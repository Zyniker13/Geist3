// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import ZTopKit

struct ZTopKitTests {
    @Test func versionMatchesTheRustCrates() {
        #expect(ZTopKit.version == "0.1.0")
    }
}
