// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Testing
@testable import ZTopKit

@Suite(.serialized)
struct TokenStoreTests {
    // Swift Testing runs tests in parallel: each test owns distinct
    // Keychain accounts so they never touch each other's entries.
    private static let host = "host-c"
    private static let port: UInt16 = 7100

    @Test func aTokenRoundTripsThroughTheKeychain() throws {
        defer { TokenStore.delete(for: Self.host, port: Self.port) }
        TokenStore.delete(for: Self.host, port: Self.port)

        #expect(TokenStore.load(for: Self.host, port: Self.port) == nil)
        try TokenStore.save("token-one", for: Self.host, port: Self.port)
        #expect(TokenStore.load(for: Self.host, port: Self.port) == "token-one")
        try TokenStore.save("token-two", for: Self.host, port: Self.port)
        #expect(TokenStore.load(for: Self.host, port: Self.port) == "token-two")
        TokenStore.delete(for: Self.host, port: Self.port)
        #expect(TokenStore.load(for: Self.host, port: Self.port) == nil)
    }

    @Test func distinctHostsKeepDistinctTokens() throws {
        defer { TokenStore.delete(for: Self.host, port: Self.port) }
        defer { TokenStore.delete(for: "host-b", port: Self.port) }
        TokenStore.delete(for: Self.host, port: Self.port)
        TokenStore.delete(for: "host-b", port: Self.port)

        try TokenStore.save("token-a", for: Self.host, port: Self.port)
        try TokenStore.save("token-b", for: "host-b", port: Self.port)
        #expect(TokenStore.load(for: Self.host, port: Self.port) == "token-a")
        #expect(TokenStore.load(for: "host-b", port: Self.port) == "token-b")
    }
}
