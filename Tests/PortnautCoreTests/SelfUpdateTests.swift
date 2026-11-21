import Foundation
import Testing
@testable import PortnautCore

@Suite
struct SelfUpdateTests {
    /// 32 bytes, as Sparkle's generate_keys prints a public key.
    let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func testUpdaterNeedsAFeedAndAPublicKey() {
        #expect(SelfUpdate.isConfigured(["SUFeedURL": SelfUpdate.feedURL, "SUPublicEDKey": key]))
        #expect(SelfUpdate.isConfigured(["SUFeedURL": "http://127.0.0.1:8765/appcast.xml", "SUPublicEDKey": key]))
        #expect(!SelfUpdate.isConfigured(["SUFeedURL": SelfUpdate.feedURL]))
        #expect(!SelfUpdate.isConfigured(["SUPublicEDKey": key]))
        #expect(!SelfUpdate.isConfigured(["SUFeedURL": "portnaut.com/appcast.xml", "SUPublicEDKey": key]))
        #expect(!SelfUpdate.isConfigured(["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": key]))
        #expect(!SelfUpdate.isConfigured(["SUFeedURL": SelfUpdate.feedURL, "SUPublicEDKey": "not a key"]))
        #expect(!SelfUpdate.isConfigured(["SUFeedURL": SelfUpdate.feedURL, "SUPublicEDKey": Data(count: 16).base64EncodedString()]))
    }

    @Test func testUpdatesWaitForGamesAndWork() {
        #expect(SelfUpdate.mayInstallNow(runningBottles: 0, busy: false))
        #expect(!SelfUpdate.mayInstallNow(runningBottles: 1, busy: false))
        #expect(!SelfUpdate.mayInstallNow(runningBottles: 0, busy: true))
    }

    /// The Info.plist that releases are built from reads the newest GitHub release and never installs silently.
    @Test func testReleaseInfoPlistUpdatesFromGitHubReleases() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect(info["SUFeedURL"] as? String == SelfUpdate.feedURL)
        // Built by Argo's update key (Keychain account "portnaut"); changing it strands every installed copy.
        #expect(info["SUPublicEDKey"] as? String == "hxml56rPSYv3Ix/4b71cWwDXEhre9w11h0Z+77nXxEY=")
        #expect(SelfUpdate.isConfigured(info))
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUEnableSystemProfiling"] == nil)
        #expect(info["NSAppTransportSecurity"] == nil)
        // Without it macOS hands Wine silence instead of asking for the microphone (voice chat in games).
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
    }
}
