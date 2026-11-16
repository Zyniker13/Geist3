// SPDX-License-Identifier: MIT OR Apache-2.0
import Testing
import Foundation
@testable import ZTopKit

/// The hub pieces: the agents.json the hub polls from and the
/// launchd plist the app installs for the login item. The hub's own
/// validation is the standard these files must meet.
@Suite
struct HubKitTests {
    /// Empty pin and token are omitted, present ones written; the
    /// hub rejects a present-but-empty pin (`SHA256:<64 hex>` only).
    @Test func agentsFileOmitsEmptyFields() throws {
        let file = HubAgentsFile(agents: [
            HubAgentSpec(name: "host-a", target: "127.0.0.1:7153"),
            HubAgentSpec(
                name: "host-b",
                target: "10.0.0.2:7100",
                pin: "SHA256:3f99288ce4dd6a6862201f23a569bd7a8af5399b4d235b1909367041e2f343ed",
                token: "tok-b"
            ),
        ])
        let text = String(data: try file.jsonData(), encoding: .utf8)!
        #expect(text.contains("\"name\" : \"host-a\""))
        #expect(!text.contains("\"pin\" : \"\""))
        #expect(!text.contains("\"token\" : \"\""))
        #expect(text.contains("SHA256:3f99288c"))
        #expect(text.contains("\"token\" : \"tok-b\""))

        let back = try HubAgentsFile.decode(Data(text.utf8))
        #expect(back.agents[0].pin == "" && back.agents[0].token == "")
        #expect(back.agents[1].pin.hasPrefix("SHA256:") && back.agents[1].token == "tok-b")
    }

    /// The argument list is the one hub configuration both paths
    /// share, and the plist embeds exactly it.
    @Test func plistEmbedsTheSharedArguments() {
        let arguments = HubPlan.arguments(port: 7101)
        #expect(arguments == ["hub", "--port", "7101", "--bind", "127.0.0.1", "--tls", "--pair"])

        let plist = HubPlan.plistXML(
            binaryPath: "/Applications/zTop.app/Contents/MacOS/ztop-embedded",
            stateDir: "/Users/example/Library/Application Support/ztop",
            port: 7101
        )
        #expect(plist.contains("<string>/Applications/zTop.app/Contents/MacOS/ztop-embedded</string>"))
        for argument in arguments.dropFirst() where argument != "--port" && argument != "7101" {
            #expect(plist.contains("<string>\(argument)</string>"))
        }
        #expect(plist.contains("<string>--port</string>"))
        #expect(plist.contains("<string>7101</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("Application Support/ztop/hub.log"))
        #expect(plist.contains("dev.ztop.hub"))
    }

    /// The plist is well-formed XML, so launchd can parse it.
    @Test func plistParsesAsXML() throws {
        let plist = HubPlan.plistXML(
            binaryPath: "/a&b/ztop-embedded",
            stateDir: "/s",
            port: 7101
        )
        #expect(plist.contains("&amp;"))
        #expect(!plist.contains("/a&b/"))
        let document = try XMLDocument(data: Data(plist.utf8))
        #expect(document.rootElement()?.name == "plist")
    }
}
