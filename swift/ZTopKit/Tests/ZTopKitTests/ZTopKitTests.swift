// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing

@testable import ZTopKit

struct ZTopKitTests {
    @Test func versionMatchesTheRustCrates() {
        #expect(ZTopKitVersion.version == "0.1.0")
    }
}
